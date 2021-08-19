Elect a kubernetes leader for life using leases for ruby.

- elects a new leader when the old leader fails to update it's lease
- waits until the current pod is the leader, then continues reporting "I am the leader" metric
- lease is a simple crd that does not do anything under the hood, except get GCed when the owning pod is deleted
- leader continuously updates the lease to signal that it's healthy
- follower determines the leader is dead when lease is not updated (avoid az outage zombie pod issues)

similar to kubernetes go implementation:
- https://github.com/kubernetes/client-go/blob/master/tools/leaderelection/leaderelection.go
- https://github.com/kubernetes/client-go/blob/master/tools/leaderelection/resourcelock/leaselock.go

Assumes that you use:
- statsd for metrics, for example [dogstatsd-ruby](https://github.com/DataDog/dogstatsd-ruby)
- [kubeclient](https://github.com/abonas/kubeclient)
- a logger that supports hashes as message

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

Needs env vars:
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

Install
=======

```Bash
gem install kubernetes_leader_election
```

Usage
=====

```Ruby
# wait for leader eletor to be elected
Thread.abort_on_exception = true
require "kubernetes_leader_election"

kubeclient = KubeClient.new("#{url}/apis/coordination.k8s.io", "v1")
statsd = Datadog::Statsd.new
logger = Logger.new STDOUT

is_leader = false
elector = KubernetesLeaderElection.new("my-app", kubeclient, statsd: statsd, logger: logger)
Thread.new { elector.become_leader_for_life { is_leader = true } }
sleep 1 until is_leader

# ... things the leader would do goes here
```

Author
======
[Michael Grosser](http://grosser.it)<br/>
michael@grosser.it<br/>
License: MIT<br/>
[![Build Status](https://travis-ci.org/grosser/kubernetes_leader_election.svg)](https://travis-ci.org/grosser/kubernetes_leader_election)
[![coverage](https://img.shields.io/badge/coverage-100%25-success.svg)](https://github.com/grosser/single_cov)
