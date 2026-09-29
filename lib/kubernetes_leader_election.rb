# frozen_string_literal: true
require 'time'
require 'openssl'
require 'timeout'
require 'kubeclient'

class KubernetesLeaderElection
  CONFLICT_CODE = 409
  FAILED_KUBERNETES_REQUEST =
    [Timeout::Error, OpenSSL::SSL::SSLError, Kubeclient::HttpError, SystemCallError, HTTP::ConnectionError].freeze

  def initialize(name, kubeclient, logger:, statsd: nil, interval: 30, retry_backoffs: [0.1, 0.5, 1, 2, 4])
    @name = name
    @kubeclient = kubeclient
    @statsd = statsd
    @logger = logger
    @interval = interval
    @retry_backoffs = retry_backoffs
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
      @statsd&.increment('leader_running') # we monitor this to make sure it's always exactly 1
      sleep @interval
      signal_alive
    end
  end

  private

  # allow callers to use any refresh tokens for their kubeclient
  # see https://github.com/abonas/kubeclient/issues/530 for a better solution
  def kubeclient
    @kubeclient.respond_to?(:call) ? @kubeclient.call : @kubeclient
  end

  # show that we are alive or crash because we cannot reach the api (split-brain az)
  def signal_alive
    with_retries(*FAILED_KUBERNETES_REQUEST) do
      patch = { spec: { renewTime: microtime } }
      reply = kubeclient.patch_entity(
        "leases", @name, patch, 'strategic-merge-patch', ENV.fetch("POD_NAMESPACE")
      )

      current_leader = reply.dig(:spec, :holderIdentity)
      raise "Lost leadership to #{current_leader}" if current_leader != ENV.fetch("POD_NAME")
    end
  end

  # kubernetes needs exactly this format or it blows up
  def microtime
    Time.now.strftime('%FT%T.000000Z')
  end

  # leader is considered dead when it failed to renew for leaseDurationSeconds
  def alive?(lease)
    renew_time = Time.parse(lease.dig(:spec, :renewTime))
    duration = lease.dig(:spec, :leaseDurationSeconds)
    renew_time + duration > Time.now
  end

  # client-go style: read the lease, create it when missing, take it over via atomic update when the holder is dead
  # see tryAcquireOrRenew https://github.com/kubernetes/client-go/blob/master/tools/leaderelection/leaderelection.go
  # leases get GCed via ownerReferences when the owning pod is deleted
  def become_leader
    namespace = ENV.fetch("POD_NAMESPACE")
    pod = ENV.fetch("POD_NAME")

    lease = with_retries(*FAILED_KUBERNETES_REQUEST) do
      kubeclient.get_entity("leases", @name, namespace)
    rescue Kubeclient::ResourceNotFoundError
      nil
    end

    if !lease
      create_lease(namespace, pod)
    elsif lease.dig(:spec, :holderIdentity) == pod
      @logger.info message: "still leader"
      true # I restarted and am still the leader
    elsif alive?(lease)
      false # leader is still alive ... not logging to avoid repetitive noise
    else
      acquire_lease(lease, namespace, pod)
    end
  end

  def create_lease(namespace, pod)
    with_retries(*FAILED_KUBERNETES_REQUEST, reraise: ->(e) { conflict?(e) }) do
      kubeclient.create_entity(
        "Lease",
        "leases",
        metadata: { name: @name, namespace: namespace, ownerReferences: [pod_owner(pod)] },
        spec: lease_spec(pod, 0)
      )
    end
    @logger.info message: "became leader"
    true # I'm the leader now
  rescue Kubeclient::HttpError => e
    raise e unless conflict?(e)
    false # someone else created it first, next loop will follow or acquire
  end

  # update with resourceVersion so exactly one contender wins
  def acquire_lease(lease, namespace, pod)
    with_retries(*FAILED_KUBERNETES_REQUEST, reraise: ->(e) { conflict?(e) }) do
      kubeclient.update_entity(
        "leases",
        metadata: {
          name: @name,
          namespace: namespace,
          resourceVersion: lease.dig(:metadata, :resourceVersion),
          ownerReferences: [pod_owner(pod)]
        },
        spec: lease_spec(pod, lease.dig(:spec, :leaseTransitions).to_i + 1)
      )
    end
    @logger.info message: "became leader"
    true
  rescue Kubeclient::HttpError => e
    raise e unless conflict?(e)
    false # lost the race, next loop will follow or acquire
  end

  def lease_spec(pod, transitions)
    now = microtime
    {
      acquireTime: now,
      holderIdentity: pod, # shown in `kubectl get lease`
      leaseDurationSeconds: @interval * 2,
      leaseTransitions: transitions,
      renewTime: now
    }
  end

  def pod_owner(pod)
    { apiVersion: "v1", kind: "Pod", name: pod, uid: ENV.fetch("POD_UID") }
  end

  def conflict?(error)
    error.is_a?(Kubeclient::HttpError) && error.error_code == CONFLICT_CODE
  end

  def with_retries(*errors, times: @retry_backoffs.size, reraise: nil)
    yield
  rescue *errors => e
    retries ||= -1
    retries += 1
    raise if retries >= times || reraise&.call(e)
    @logger.warn message: "Retryable error", type: e.class.to_s, retries: times - retries
    sleep @retry_backoffs[retries] || @retry_backoffs.last
    retry
  end
end
