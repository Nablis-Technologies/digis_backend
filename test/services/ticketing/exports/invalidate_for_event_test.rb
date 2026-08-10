# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Exports
    class InvalidateForEventTest < ActiveSupport::TestCase
      include Ticketing::AttendeeExportTestHelpers

      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @exports = %w[pending processing ready failed].map do |status|
          create_export(event: @event, actor: @actor, overrides: { status: })
        end
      end

      test "moves every active export to expiring and publishes one purge event" do
        result = InvalidateForEvent.call(event: @event)

        assert_predicate result, :success?, result.error&.message
        assert_equal @exports.map(&:id).sort, Ticketing::AttendeeExport.where(status: "expiring").pluck(:id).sort
        assert_equal @exports.length, Core::OutboxEvent.where(
          event_type: "ticketing.attendee_export.purge_requested"
        ).count
        assert_equal @exports.length, Core::AuditLog.where(
          action: "ticketing.attendee_export.invalidated"
        ).count
      end

      test "is idempotent across a repeated invalidation" do
        subject = -> { InvalidateForEvent.call(event: @event) }

        assert_idempotent(
          subject,
          counter: -> { Core::OutboxEvent.where(event_type: "ticketing.attendee_export.purge_requested").count }
        )
      end
    end
  end
end
