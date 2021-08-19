# frozen_string_literal: true
require 'time'
require 'openssl'
require 'timeout'
require 'kubeclient'

class KubernetesLeaderElection
  ALREADY_EXISTS_CODE = 409
  FAILED_KUBERNETES_REQUEST =
    [Timeout::Error, OpenSSL::SSL::SSLError, Kubeclient::HttpError, SystemCallError, HTTP::ConnectionError].freeze

  def initialize(name, kubeclient, statsd:, logger:, interval: 30)
    @name = name
    @kubeclient = kubeclient
    @statsd = statsd
    @logger = logger
    @interval = interval
  end

  # not using `call` since we never want to be restarted
  def become_leader_for_life
    @logger.info message: "trying to become leader ... if both pods show this, delete the #{@name} lease"
    loop do
      break if become_leader
      sleep @interval
    end
    yield # signal we are leader, but keep reporting
    loop do
      @statsd.increment('leader_running') # we monitor this to make sure it's always exactly 1
      sleep @interval
      signal_alive
    end
  end

  private

  # show that we are alive or crash because we cannot reach the api (split-brain az)
  def signal_alive
    with_retries(*FAILED_KUBERNETES_REQUEST, times: 3) do
      patch = { spec: { renewTime: microtime } }
      reply = @kubeclient.patch_entity(
        "leases", @name, patch, 'strategic-merge-patch', ENV.fetch("POD_NAMESPACE")
      )

      current_leader = reply.dig(:metadata, :ownerReferences, 0, :name)
      raise "Lost leadership to #{current_leader}" if current_leader != ENV.fetch("POD_NAME")
    end
  end

  # kubernetes needs exactly this format or it blows up
  def microtime
    Time.now.strftime('%FT%T.000000Z')
  end

  def alive?(lease)
    Time.parse(lease.dig(:spec, :renewTime)) > Time.now - (2 * @interval)
  end

  # everyone tries to create the same leases, who succeeds is the owner,
  # leases is auto-deleted by GC when owner is deleted
  # same logic lives in kube-service-watcher & kube-stats
  def become_leader
    namespace = ENV.fetch("POD_NAMESPACE")
    # retry request on regular api errors
    reraise = ->(e) { e.is_a?(Kubeclient::HttpError) && e.error_code == ALREADY_EXISTS_CODE }

    with_retries(*FAILED_KUBERNETES_REQUEST, reraise: reraise, times: 3) do
      @kubeclient.create_entity(
        "Lease",
        "leases",
        metadata: {
          name: @name,
          namespace: namespace,
          ownerReferences: [{
            apiVersion: "v1",
            kind: "Pod",
            name: ENV.fetch("POD_NAME"),
            uid: ENV.fetch("POD_UID")
          }]
        },
        spec: {
          acquireTime: microtime,
          holderIdentity: ENV.fetch("POD_NAME"), # shown in `kubectl get lease`
          leaseDurationSeconds: @interval * 2,
          leaseTransitions: 0, # will never change since we delete the lease
          renewTime: microtime
        }
      )
    end
    @logger.info message: "became leader"
    true # I'm the leader now
  rescue Kubeclient::HttpError => e
    raise e unless e.error_code == ALREADY_EXISTS_CODE # lease already exists

    lease = with_retries(*FAILED_KUBERNETES_REQUEST, times: 3) do
      @kubeclient.get_entity("leases", @name, namespace)
    end
    leader = lease.dig(:metadata, :ownerReferences, 0, :name)
    if leader == ENV.fetch("POD_NAME")
      @logger.info message: "still leader"
      true # I restarted and am still the leader
    elsif !alive?(lease)
      @logger.info message: "deleting stale lease"
      with_retries(*FAILED_KUBERNETES_REQUEST, times: 3) do
        @kubeclient.delete_entity("leases", @name, namespace)
      end
      false
    else
      false # leader is still alive ... not logging to avoid repetitive noise
    end
  end

  def with_retries(*errors, times:, reraise: nil, backoff: [0.1, 0.5, 1])
    yield
  rescue *errors => e
    retries ||= -1
    retries += 1
    raise if retries >= times || reraise&.call(e)
    @logger.warn message: "Retryable error", type: e.class.to_s, retries: times - retries
    sleep backoff[retries] || backoff.last
    retry
  end
end
