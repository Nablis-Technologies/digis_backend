# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

module Events
  module Recurrence
    class ConfigureTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      def valid_attributes
        {
          rrule: "FREQ=DAILY;COUNT=3",
          timezone: "Africa/Addis_Ababa",
          dtstart_local: Time.zone.local(2026, 8, 1, 20, 0, 0),
          duration_seconds: 3600
        }
      end

      test "creates a recurrence rule and enqueues materialization" do
        event = events_events(:ready_listing)

        assert_enqueued_with(job: Events::MaterializeRecurrenceJob) do
          result = Events::Recurrence::Configure.call(
            event:, actor: core_users(:core_admin), attributes: valid_attributes
          )
          assert result.success?, result.error.inspect
        end

        assert_equal 1, Events::RecurrenceRule.where(event:).count
      end

      test "reuses the existing rule when configured again" do
        event = events_events(:ready_listing)
        Events::Recurrence::Configure.call(
          event:, actor: core_users(:core_admin), attributes: valid_attributes
        )

        assert_enqueued_with(job: Events::MaterializeRecurrenceJob) do
          result = Events::Recurrence::Configure.call(
            event:, actor: core_users(:core_admin),
            attributes: valid_attributes.merge(rrule: "FREQ=WEEKLY;COUNT=2")
          )
          assert result.success?, result.error.inspect
        end

        assert_equal 1, Events::RecurrenceRule.where(event:).count
        assert_equal "FREQ=WEEKLY;COUNT=2", event.reload.recurrence_rule.rrule
      end

      test "returns a failure for invalid attributes" do
        event = events_events(:ready_listing)

        assert_no_enqueued_jobs do
          result = Events::Recurrence::Configure.call(
            event:, actor: core_users(:core_admin),
            attributes: { rrule: "", timezone: "", duration_seconds: 0 }
          )
          assert result.failure?
          assert_equal "invalid", result.error.code
        end

        assert_equal 0, Events::RecurrenceRule.where(event:).count
      end

      test "configuring a rule writes an audit entry" do
        event = events_events(:ready_listing)
        result = Events::Recurrence::Configure.call(
          event:, actor: core_users(:core_admin), attributes: valid_attributes
        )
        assert result.success?
        assert Core::AuditLog.exists?(
          action: "event.recurrence.configured",
          auditable_type: "Events::RecurrenceRule",
          auditable_id: result.value.id
        )
      end

      test "replaying an identical configure is idempotent with respect to the audit log" do
        event = events_events(:ready_listing)
        subject = lambda do
          Events::Recurrence::Configure.call(event:, actor: core_users(:core_admin), attributes: valid_attributes)
        end
        assert_audit_idempotent(
          subject,
          action: "event.recurrence.configured",
          auditable_type: "Events::RecurrenceRule",
          auditable_id: -> { Events::RecurrenceRule.where(event:).first&.id }
        )
      end

      test "deleting a configured rule removes its generated dates" do
        event = events_events(:ready_listing)
        Events::Recurrence::Configure.call(
          event:, actor: core_users(:core_admin), attributes: valid_attributes
        )
        perform_enqueued_jobs

        assert event.event_dates.count.positive?

        event.recurrence_rule.destroy!

        assert_equal 0, event.reload.event_dates.count
        assert_nil event.reload.recurrence_rule
      end
    end
  end
end
