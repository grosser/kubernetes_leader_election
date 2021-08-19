# frozen_string_literal: true
require "bundler/setup"

require "single_cov"
SingleCov.setup :minitest

require "maxitest/global_must"
require "maxitest/autorun"

require "kubernetes_leader_election/version"
require "kubernetes_leader_election"
