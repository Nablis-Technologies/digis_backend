# frozen_string_literal: true

require "test_helper"

module Commercial
  module Versions
    class TerminateTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @version = create_active_version(code: "version_terminate")
      end

      test "terminates an active version with durable evidence" do
        result = Terminate.call(
          version: @version, actor: core_users(:super_admin), reason: "Policy retirement",
          idempotency_key: "version-terminate-1"
        )

        assert result.success?, result.error&.message
        assert_equal "terminated", result.value.status
        assert_equal 1, Core::OutboxEvent.where(event_type: "commercial.version.terminated").count
      end
    end
  end
end
