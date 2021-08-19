# frozen_string_literal: true
require "bundler/setup"

require "single_cov"
SingleCov.setup :minitest

require "maxitest/global_must"
require "maxitest/autorun"
require "maxitest/timeout"
require "maxitest/threads"
require "mocha/minitest"
require "webmock/minitest"
require "logger"

require "kubernetes_leader_election/version"
require "kubernetes_leader_election"

ENV["POD_NAME"] = "bar"
ENV["POD_UID"] = "id"
ENV["POD_NAMESPACE"] = "baz"

Minitest::Test.class_eval do
  def expect_log(level, times: 1)
    logger.unstub(level)
    logger.expects(level).with(anything).times(times)
  end

  def setup
    super

    logger.expects(:warn).with { |x| raise "Unexecpted warn #{x}" }.never
    logger.expects(:error).with { |x| raise "Unexecpted error #{x}" }.never
  end

  def logger
    @logger ||= Logger.new("/dev/null")
  end
end
