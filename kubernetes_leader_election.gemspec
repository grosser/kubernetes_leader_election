# frozen_string_literal: true
name = "kubernetes_leader_election"
$LOAD_PATH << File.expand_path("lib", __dir__)
require "#{name.tr("-", "/")}/version"

Gem::Specification.new name, KubernetesLeaderElection::VERSION do |s|
  s.summary = "Elect a kubernetes leader using leases for ruby"
  s.authors = ["Michael Grosser"]
  s.email = "michael@grosser.it"
  s.homepage = "https://github.com/grosser/#{name}"
  s.files = `git ls-files lib/ bin/ MIT-LICENSE`.split("\n")
  s.license = "MIT"
  s.required_ruby_version = ">= 2.6.0"
  s.add_runtime_dependency "kubeclient"
end
