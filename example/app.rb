# frozen_string_literal: true
Thread.abort_on_exception = true
$stdout.sync = true
require "logger"
logger = Logger.new $stdout

# setup
require "kubernetes_leader_election"
origin = "https://#{ENV.fetch('KUBERNETES_SERVICE_HOST')}:#{ENV.fetch('KUBERNETES_SERVICE_PORT_HTTPS')}"
kubeclient = Kubeclient::Client.new(
  "#{origin}/apis/coordination.k8s.io",
  "v1",
  auth_options: { bearer_token_file: '/var/run/secrets/kubernetes.io/serviceaccount/token' },
  ssl_options: { ca_file: '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt' }
)

# wait for leader to be elected
is_leader = false
elector = KubernetesLeaderElection.new("my-app", kubeclient, logger: logger)
Thread.new { elector.become_leader_for_life { is_leader = true } }
sleep 1 until is_leader

# do leader things
puts "I'm the leader now"
sleep
