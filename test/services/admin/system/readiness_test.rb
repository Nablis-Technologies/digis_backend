# frozen_string_literal: true

require "test_helper"

class Admin::System::ReadinessTest < ActiveSupport::TestCase
  test "checks local dependencies without calling payment providers" do
    result = Admin::System::Readiness.call

    assert_predicate result, :success?
    assert_equal %w[database encryption outbox queue storage], result.value.fetch(:components).keys.map(&:to_s).sort
    assert_includes %w[ok degraded], result.value.fetch(:status)
    refute_match(/password|secret|host|provider/i, result.value.inspect)
  end

  test "converts dependency exceptions into a degraded component without leaking details" do
    Core::ApplicationRecord.connection.stubs(:select_value).raises(StandardError, "database-password-secret")

    result = Admin::System::Readiness.call

    assert_predicate result, :success?
    assert_equal "degraded", result.value.fetch(:status)
    assert_equal "degraded", result.value.fetch(:components).fetch(:database)
    refute_includes result.value.inspect, "database-password-secret"
  end
end
