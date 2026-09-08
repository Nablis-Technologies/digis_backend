# frozen_string_literal: true

require "test_helper"

module Core
  class AuthThrottleTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

    test "limits attempts independently by IP and identifier" do
      cache = ActiveSupport::Cache::MemoryStore.new
      Rails.stubs(:cache).returns(cache)

      10.times { assert_predicate throttle, :success? }
      result = throttle
      assert_predicate result, :failure?
      assert_equal :too_many_requests, result.error.status_code

      10.times { assert_predicate throttle(identifier: "other@example.com", ip_address: "203.0.113.11"), :success? }
      assert_predicate throttle(identifier: "other@example.com", ip_address: "203.0.113.11"), :failure?
    end

    test "expires counters after the configured window" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      10.times { throttle }
      assert_predicate throttle, :failure?

      travel Core::AuthThrottle::WINDOW + 1.second

      assert_predicate throttle, :success?
    end

    test "does not put raw identifiers in cache keys" do
      cache = ActiveSupport::Cache::MemoryStore.new
      Rails.stubs(:cache).returns(cache)
      assert_predicate throttle(identifier: "person@example.com"), :success?

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
  end
end
