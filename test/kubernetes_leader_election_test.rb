# frozen_string_literal: true
require_relative "test_helper"

SingleCov.covered!

def assert_becomes_leader_if_there_is_no_leader
  stub_get.to_return(status: 404)
  stub_post.to_return(body: { items: [{}] }.to_json)
  stub_patch
  call { sleep 0.05 until @leader }
end

describe KubernetesLeaderElection do
  def stub_patch
    stub_request(:patch, lease_url).to_return(body: patch_reply.to_json)
  end

  def stub_get
    stub_request(:get, lease_url)
  end

  def stub_post
    stub_request(:post, "#{url}/v1/namespaces/baz/leases")
  end

  def stub_put
    stub_request(:put, lease_url)
  end

  def stale_lease
    {
      metadata: { resourceVersion: "1" },
      spec: { holderIdentity: "other", renewTime: Time.now - 90, leaseDurationSeconds: 60, leaseTransitions: 2 }
    }
  end

  let(:patch_reply) { { spec: { holderIdentity: ENV.fetch("POD_NAME") } } }
  let(:kubeclient) { Kubeclient::Client.new(url, "v1") }
  let(:statsd) { stub("Statsd", increment: true) }
  let(:url) { "https://kube.com/apis/coordination.k8s.io" }
  let(:lease_url) { "#{url}/v1/namespaces/baz/leases/foo" }

  it "has a VERSION" do
    KubernetesLeaderElection::VERSION.must_match /^[.\da-z]+$/
  end

  describe "#call" do
    def call(opts: {})
      t = Thread.new do
        t.report_on_exception = false # join will show exceptions
        leader = KubernetesLeaderElection.new("foo", kubeclient, statsd: statsd, logger: logger, **opts)
        leader.become_leader_for_life { @leader = true }
      end
      yield
      t.kill
      t.join # re-raise exceptions
    end

    before { KubernetesLeaderElection.any_instance.stubs(:sleep).with { sleep 0.01 } }
    after { maxitest_kill_extra_threads }

    it "becomes leader when there is no leader" do
      assert_becomes_leader_if_there_is_no_leader
    end

    it "stays leader when restarting" do
      stub_get.to_return(body: { spec: { holderIdentity: ENV.fetch("POD_NAME") } }.to_json)
      stub_patch
      call { sleep 0.05 until @leader }
    end

    it "gives up when someone else took leadership" do
      stub_get.to_return(status: 404)
      stub_post.to_return(body: { items: [{}] }.to_json)
      patch_reply[:spec][:holderIdentity] = "other"
      stub_patch
      e = assert_raises(RuntimeError) { call { sleep 0.05 } }
      e.message.must_equal "Lost leadership to other"
    end

    it "follows when there is a leader" do
      stub_get.to_return(
        body: {
          spec: { holderIdentity: "other", renewTime: Time.now, leaseDurationSeconds: 60 }
        }.to_json
      )
      call { sleep 0.05 }
      refute @leader
    end

    it "takes over when leader is dead" do
      stub_get.to_return(body: stale_lease.to_json)
      stub_put.to_return(body: "{}")
      stub_patch
      call { sleep 0.05 until @leader }
      assert_requested :put, lease_url, body: /"holderIdentity":"bar".*"leaseTransitions":3/
    end

    it "does not become leader when loosing the takeover race" do
      stub_get.to_return(body: stale_lease.to_json)
      stub_put.to_return(status: 409)
      call { sleep 0.05 }
      refute @leader
    end

    it "does not become leader when loosing the create race" do
      stub_get.to_return(status: 404)
      stub_post.to_return(status: 409)
      call { sleep 0.05 }
      refute @leader
    end

    it "raises create errors that are not conflicts" do
      KubernetesLeaderElection.any_instance.expects(:sleep).times(1)
      expect_log(:warn).times(1)
      stub_get.to_return(status: 404)
      stub_post.to_return(status: 500)
      assert_raises Kubeclient::HttpError do
        call(opts: { retry_backoffs: [0.01] }) { sleep 0.05 }
      end
    end

    it "raises update errors that are not conflicts" do
      KubernetesLeaderElection.any_instance.expects(:sleep).times(1)
      expect_log(:warn).times(1)
      stub_get.to_return(body: stale_lease.to_json)
      stub_put.to_return(status: 500)
      assert_raises Kubeclient::HttpError do
        call(opts: { retry_backoffs: [0.01] }) { sleep 0.05 }
      end
    end

    it "retries on connection errors" do
      expect_log(:warn).times(4)
      get = stub_get.to_return(
        { status: 500 },
        { status: 500 },
        { status: 500 },
        { status: 500 },
        status: 404
      )
      stub_post.to_return(body: { items: [{}] }.to_json)
      stub_patch
      call { sleep 0.05 until @leader }
      assert_requested get, times: 5
    end

    it "gives up on consistent connection errors" do
      KubernetesLeaderElection.any_instance.expects(:sleep).times(1)
      expect_log(:warn).times(1)
      get = stub_get.to_return(status: 500)
      assert_raises Kubeclient::HttpError do
        call(opts: { retry_backoffs: [0.01] }) { sleep 0.05 }
      end
      assert_requested get, times: 2
    end

    describe "with a callback kubeclient" do
      def kubeclient
        client = super
        -> do
          called << 1
          client
        end
      end

      let(:called) { [] }

      it "works" do
        assert_becomes_leader_if_there_is_no_leader
        called.size.must_be_within_delta 5, 1 # TODO: randomly is 6 in CI more
      end
    end
  end

  describe "#with_retries" do
    let(:client) { KubernetesLeaderElection.new nil, nil, statsd: nil, logger: logger }

    it "passes" do
      calls = []
      client.send(:with_retries, ArgumentError, times: 3) { calls << 1 }.must_equal [1]
    end

    it "retries and passes" do
      client.expects(:sleep).times(1)
      expect_log :warn, times: 1
      calls = []
      client.send(:with_retries, ArgumentError, times: 3) do
        calls << 1
        raise ArgumentError if calls.size == 1
        calls
      end.must_equal [1, 1]
    end

    it "retries and fails" do
      client.expects(:sleep).times(3)
      expect_log :warn, times: 3
      calls = []
      assert_raises ArgumentError do
        client.send(:with_retries, ArgumentError, times: 3) do
          calls << 1
          raise ArgumentError
        end
      end
      calls.must_equal [1, 1, 1, 1]
    end

    it "does not retry on ignored" do
      calls = []
      assert_raises ArgumentError do
        client.send(:with_retries, NotImplementedError, reraise: ->(e) { e.is_a?(ArgumentError) }, times: 3) do
          calls << 1
          raise ArgumentError, "Hi"
        end
      end.message.must_equal "Hi"
      calls.must_equal [1]
    end

    it "fails on unexpected" do
      calls = []
      assert_raises RuntimeError do
        client.send(:with_retries, ArgumentError, times: 3) do
          calls << 1
          raise RuntimeError
        end
      end
      calls.must_equal [1]
    end

    it "uses backoff for retries, repeating final backoff interval if more times are needed" do
      calls = []
      client.expects(:sleep).with { |v| calls << v }.times(6)
      expect_log :warn, times: 6
      calls = []
      assert_raises ArgumentError do
        client.send(:with_retries, ArgumentError, times: 6) { raise ArgumentError }
      end
      calls.must_equal [0.1, 0.5, 1, 2, 4, 4]
    end

    it "allows backoffs to be customized" do
      client = KubernetesLeaderElection.new nil, nil, statsd: nil, logger: logger, retry_backoffs: [0.1, 0.2]
      calls = []
      client.expects(:sleep).with { |v| calls << v }.times(4)
      expect_log :warn, times: 4
      calls = []
      assert_raises ArgumentError do
        client.send(:with_retries, ArgumentError, times: 4) { raise ArgumentError }
      end
      calls.must_equal [0.1, 0.2, 0.2, 0.2]
    end
  end
end
