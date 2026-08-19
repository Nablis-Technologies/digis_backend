# frozen_string_literal: true

require "test_helper"

module Commercial
  module OutboxHandlers
    class BreakGlassTest < ActiveSupport::TestCase
      test "acknowledges a valid break-glass event and emits a security notification" do
        event = security_event(operation: "assignment_approve")
        notifications = []

        ActiveSupport::Notifications.subscribed(
          ->(*args) { notifications << args.last },
          "commercial.security.break_glass"
        ) do
          result = BreakGlass.call(event:)
          assert result.success?, result.error&.message
        end

        assert_equal 1, notifications.length
        assert_equal event.id, notifications.first.fetch(:event_id)
        assert_equal "assignment_approve", notifications.first.fetch(:operation)
      end

      test "rejects a malformed break-glass event" do
        event = security_event(operation: nil)

        result = BreakGlass.call(event:)

        assert result.failure?
        assert_equal "invalid_security_event", result.error.code
      end

      private

      def security_event(operation:)
        event = core_outbox_events(:pending)
        event.update!(
          topic: "security",
          event_type: "commercial.security.break_glass",
          aggregate_type: "Commercial::Assignment",
          aggregate_id: SecureRandom.uuid,
          payload: { assignment_id: SecureRandom.uuid, operation: }
        )
        event
      end
    end
  end
end
