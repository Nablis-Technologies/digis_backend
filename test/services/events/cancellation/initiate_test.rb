# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

module Events
  module Cancellation
    class InitiateTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      def setup
        @event = events_events(:ready_listing)
        @actor = core_users(:core_admin)
      end

      def call(key: "cancel-1", internal_note: nil, attendee_reason: "The event will not proceed.")
        Events::Cancellation::Initiate.call(
          event: @event, actor: @actor,
          internal_note:, attendee_reason:, idempotency_key: key
        )
      end

      test "stops the event immediately by cancelling it" do
        result = call
        assert result.success?, result.error&.inspect

        assert_equal "cancelled", @event.reload.status
        assert_not_nil @event.cancelled_at
        assert_equal 1, Events::EventCancellation.where(event: @event).count
      end

      test "records the cancellation with a pending status" do
        result = call(internal_note: "venue lost", attendee_reason: "sorry")
        cancellation = result.value

        assert_equal "pending", cancellation.status
        assert_equal @actor.id, cancellation.initiated_by_id
        assert_equal "venue lost", cancellation.internal_note
        assert_equal "sorry", cancellation.attendee_reason
      end

      test "retains published_at for history when cancelling a published event" do
        @event.update!(status: "published", published_at: Time.current)
        published_at = @event.reload.published_at

        result = call
        assert result.success?, result.error&.inspect

        assert_equal "cancelled", @event.reload.status
        assert_in_delta published_at.to_f, @event.published_at.to_f, 1
      end

      test "rejects a second cancellation for the same event" do
        call(key: "first")
        result = call(key: "second")

        assert result.failure?
        assert_equal "already_cancelled", result.error.code
        assert_equal 1, Events::EventCancellation.where(event: @event).count
      end

      test "publishes exactly one cancellation-initiated outbox event" do
        assert_difference -> { Core::OutboxEvent.where(event_type: "events.cancellation_initiated").count }, 1 do
          call
        end
      end

      test "is idempotent for a repeated idempotency key" do
        subject = -> { call(key: "same") }
        assert_audit_idempotent(
          subject,
          action: "event.cancellation.initiated",
          auditable_type: "Events::Event",
          auditable_id: @event.id
        )
      end

      test "enqueues only the stream sync job and never a payment job" do
        assert_enqueued_jobs 1, only: Events::SyncStreamScheduleJob do
          call
        end
      end

      test "writes an audit entry for the cancellation" do
        result = call
        assert result.success?
        assert Core::AuditLog.exists?(
          action: "event.cancellation.initiated",
          auditable_type: "Events::Event",
          auditable_id: @event.id
        )
      end
    end
  end
end
