# frozen_string_literal: true

require "test_helper"

module Events
  module Recurrence
    class ActivateDeactivateTest < ActiveSupport::TestCase
      def valid_attributes
        {
          rrule: "FREQ=DAILY;COUNT=3",
          timezone: "Africa/Addis_Ababa",
          dtstart_local: Time.zone.local(2026, 8, 1, 20, 0, 0),
          duration_seconds: 3600
        }
      end

      def persisted_rule
        Events::Recurrence::Configure.call(
          event: events_events(:ready_listing),
          actor: core_users(:core_admin),
          attributes: valid_attributes
        ).value
      end

      test "Activate flips active to true and audits" do
        rule = persisted_rule
        rule.update!(active: false)

        result = Events::Recurrence::Activate.call(rule:, actor: core_users(:core_admin))
        assert result.success?
        assert rule.reload.active?
        assert Core::AuditLog.exists?(
          action: "event.recurrence.activated",
          auditable_type: "Events::RecurrenceRule",
          auditable_id: rule.id
        )
      end

      test "Activate is idempotent when already active" do
        rule = persisted_rule
        assert rule.active?

        assert_no_changes -> { rule.reload.updated_at } do
          result = Events::Recurrence::Activate.call(rule:, actor: core_users(:core_admin))
          assert result.success?
        end
        assert rule.reload.active?
      end

      test "Deactivate flips active to false and audits" do
        rule = persisted_rule

        result = Events::Recurrence::Deactivate.call(rule:, actor: core_users(:core_admin))
        assert result.success?
        assert_not rule.reload.active?
        assert Core::AuditLog.exists?(
          action: "event.recurrence.deactivated",
          auditable_type: "Events::RecurrenceRule",
          auditable_id: rule.id
        )
      end

      test "Deactivate is idempotent when already inactive" do
        rule = persisted_rule
        rule.update!(active: false)

        assert_no_changes -> { rule.reload.updated_at } do
          result = Events::Recurrence::Deactivate.call(rule:, actor: core_users(:core_admin))
          assert result.success?
        end
        assert_not rule.reload.active?
      end
    end
  end
end
