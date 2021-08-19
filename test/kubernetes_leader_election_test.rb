# frozen_string_literal: true
require_relative "test_helper"

SingleCov.covered!

describe KubernetesLeaderElection do
  it "has a VERSION" do
    KubernetesLeaderElection::VERSION.must_match /^[.\da-z]+$/
  end
end
