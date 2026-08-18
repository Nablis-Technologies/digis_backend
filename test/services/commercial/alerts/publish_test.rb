# frozen_string_literal: true

require "test_helper"

module Commercial
  module Alerts
    class PublishTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @version = create_active_version(code: "task12_alerts")
      end

      test "publishes one deduplicated operational event for identical evidence" do
        details = { source: "grandfather_period", expires_at: 1.day.from_now.iso8601(6) }

        first = Commercial::Alerts::Publish.call(kind: "grandfather_expiring", aggregate: @version, details:)
        second = Commercial::Alerts::Publish.call(kind: "grandfather_expiring", aggregate: @version, details:)

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal 1, Core::AuditLog.where(action: "commercial.operational_alert").count
        assert_equal 1, Core::OutboxEvent.where(event_type: "commercial.operational_alert").count
        assert_equal first.value.id, second.value.id
      end
    end
  end
end
