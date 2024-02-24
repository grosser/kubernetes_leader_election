Elect a kubernetes leader for life using leases for ruby.

- elects a new leader when the old leader pod is deleted
- elects a new leader when the old leader pod fails to update it's lease (see [race condition issue](https://github.com/kubernetes/kubernetes/issues/20572))
- waits until the current pod is the leader, then continues reporting "I am the leader" metric
- lease is a simple crd that does not do anything under the hood, except get GCed when the owning pod is deleted
- leader continuously updates the lease to signal that it's healthy
- follower determines the leader is dead when lease is not updated (avoid az outage zombie pod issues)

similar to kubernetes go implementation:
- https://github.com/kubernetes/client-go/blob/master/tools/leaderelection/leaderelection.go
- https://github.com/kubernetes/client-go/blob/master/tools/leaderelection/resourcelock/leaselock.go

Works best with:
- statsd for metrics, for example [dogstatsd-ruby]
- [kubeclient](https://github.com/abonas/kubeclient)

[dogstatsd-ruby]: https://github.com/DataDog/dogstatsd-ruby

Install
=======

```Bash
gem install kubernetes_leader_election
```

Usage
=====

```Ruby
Thread.abort_on_exception = true
$stdout.sync = true
require "logger"
logger = Logger.new STDOUT

# setup
require "kubernetes_leader_election"
origin = "https://#{ENV.fetch('KUBERNETES_SERVICE_HOST')}:#{ENV.fetch('KUBERNETES_SERVICE_PORT_HTTPS')}"
kubeclient = Kubeclient::Client.new(
  "#{origin}/apis/coordination.k8s.io",
  "v1",
  auth_options: {bearer_token_file: '/var/run/secrets/kubernetes.io/serviceaccount/token'},
  ssl_options: {ca_file: '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'}
)

# wait for leader to be elected
is_leader = false
elector = KubernetesLeaderElection.new("my-app", kubeclient, logger: logger)
Thread.new { elector.become_leader_for_life { is_leader = true } }
sleep 1 until is_leader

# do leader things
puts "I'm the leader now"
sleep
```

### Configuration options

The `KubernetesLeaderElection` object can be configured to suit your unique
needs in a few ways. The default values should work for most people, but,
when initializing the object, you can pass the following arguments:

| Argument         | What it does                                                                                                                             | Default                            |
| --------         | ------------                                                                                                                             | -------                            |
| `statsd`         | Allows you to pass a StatsD client, e.g. [dogstatsd-ruby], for recording metrics about the leader                                        | `nil` (no StatsD metrics are sent) |
| `interval`       | Sets the interval to refresh the Lease. The `leaseDurationSeconds` will be double this value.                                            | `30`                               |
| `retry_backoffs` | If a request to the Kuberenetes API fails, it will be retried, with each element being the sleep interval between each successive retry. | `[0.1, 0.5, 1, 2, 4]`              |

### Example

see `example/` folder

### RBAC

Needs permissions:
```yaml
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["create"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  resourceNames: ["my-app"]
  verbs: ["get", "patch", "delete"]
```

### Env vars
```yaml
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_UID
  valueFrom:
    fieldRef:
      fieldPath: metadata.uid
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
```

### BoundServiceAccountTokenVolume

When using service account tokens from disk, then provide a method that builds a kubeclient instead of a kubeclient object.
Ideally cache for <=1h so the token never expires.

```ruby
kubeclient = -> { cache.fetch(:kubclient) { Kubeclient.new(...) } }
elector = KubernetesLeaderElection.new("my-app", kubeclient, logger: logger)
```

Author
======
[Michael Grosser](http://grosser.it)<br/>
michael@grosser.it<br/>
License: MIT<br/>
[![CI](https://github.com/grosser/kubernetes_leader_election/actions/workflows/actions.yml/badge.svg)](https://github.com/grosser/kubernetes_leader_election/actions/workflows/actions.yml?query=branch%3Amaster)
[![coverage](https://img.shields.io/badge/coverage-100%25-success.svg)](https://github.com/grosser/single_cov)
