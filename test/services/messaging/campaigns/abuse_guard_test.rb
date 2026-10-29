# frozen_string_literal: true

require "test_helper"

module Messaging
  module Campaigns
    class AbuseGuardTest < ActiveSupport::TestCase
      test "allows requests below the configured limit and rejects the next one" do
        cache = ActiveSupport::Cache::MemoryStore.new
        Rails.stubs(:cache).returns(cache)

        first = AbuseGuard.call(scope: "unsubscribe", identity: "127.0.0.1", limit: 1)
        second = AbuseGuard.call(scope: "unsubscribe", identity: "127.0.0.1", limit: 1)

        assert first.success?
        assert_equal "rate_limited", second.error.code
        assert_equal :too_many_requests, second.error.status_code
      end
    end
  end
end
