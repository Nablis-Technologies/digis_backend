# frozen_string_literal: true

require "test_helper"

module Core
  class AuthThrottleTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

    test "counts recorded failures without consuming the budget for successful requests" do
      cache = ActiveSupport::Cache::MemoryStore.new
      Rails.stubs(:cache).returns(cache)

      10.times { assert_predicate throttle, :success? }
      assert_predicate throttle, :success?

      10.times { assert_predicate record_failure, :success? }
      result = throttle
      assert_predicate result, :failure?
      assert_equal :too_many_requests, result.error.status_code

      other = throttle(identifier: "other@example.com", ip_address: "203.0.113.11")
      assert_predicate other, :success?
    end

    test "expires counters after the configured window" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      10.times { record_failure }
      assert_predicate throttle, :failure?

      travel Core::AuthThrottle::WINDOW + 1.second

      assert_predicate throttle, :success?
    end

    test "does not put raw identifiers in cache keys" do
      cache = ActiveSupport::Cache::MemoryStore.new
      Rails.stubs(:cache).returns(cache)
      assert_predicate record_failure(identifier: "person@example.com"), :success?

      cache.instance_variable_get(:@data).keys.map(&:to_s).each do |key|
        refute_includes key, "person@example.com"
        refute_includes key, "203.0.113.10"
        assert_match(/[0-9a-f]{64}/, key)
      end
    end

    private

    def throttle(identifier: "person@example.com", ip_address: "203.0.113.10")
      Core::AuthThrottle.new(identifier:, ip_address:).call
    end

    def record_failure(identifier: "person@example.com", ip_address: "203.0.113.10")
      Core::AuthThrottle.new(identifier:, ip_address:).record_failure
    end
  end
end
