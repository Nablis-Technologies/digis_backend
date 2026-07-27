# frozen_string_literal: true

require "test_helper"

module Events
  class RecurrenceRulesControllerAuditTest < ActiveSupport::TestCase
    def setup
      @event = events_events(:ready_listing)
      @user = core_users(:core_admin)
      @rule = Events::RecurrenceRule.create!(
        event: @event,
        rrule: "FREQ=DAILY;COUNT=1",
        timezone: "Africa/Addis_Ababa",
        dtstart_local: Time.zone.local(2026, 8, 1, 20, 0, 0),
        duration_seconds: 3600
      )
    end

    test "destroy audit is idempotent with respect to the audit log" do
      controller = Events::RecurrenceRulesController.new
      controller.instance_variable_set(:@rule, @rule)
      controller.instance_variable_set(:@event, @event)
      user = @user
      subject = lambda do
        controller.define_singleton_method(:current_user) { user }
        controller.send(:record_audit)
      end
      assert_audit_idempotent(
        subject,
        action: "event.recurrence.removed",
        auditable_type: "Events::RecurrenceRule",
        auditable_id: @rule.id
      )
    end
  end
end
