# frozen_string_literal: true

require "test_helper"

module Messaging
  class MarkNotificationReadTest < ActiveSupport::TestCase
    setup do
      @user = core_users(:attendee)
      Core::DataRetentionPolicy.create!(
        category: "messaging_notification",
        version: 1,
        action: "erase_payload",
        retention_days: 365,
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )
      @notification = create_notification(user: @user)
    end

    test "mark read is a naturally idempotent state set" do
      result = Messaging::MarkNotificationRead.call(notification: @notification, user: @user)
      assert_predicate result, :success?, result.error&.message
      first_read_at = result.value.read_at

      replay = Messaging::MarkNotificationRead.call(notification: @notification, user: @user)
      assert_predicate replay, :success?, replay.error&.message
      assert_equal first_read_at, replay.value.read_at
    end

    test "another user cannot mark the notification read" do
      result = Messaging::MarkNotificationRead.call(
        notification: @notification, user: core_users(:core_admin)
      )

      assert_predicate result, :failure?
      assert_equal "notification_not_found", result.error.code
    end

    private

    def create_notification(user:)
      policy = Core::DataRetentionPolicy.active.find_by!(category: "messaging_notification")
      Messaging::Notification.create!(
        user:, notification_type: "schedule_changed", category: "transactional",
        source: events_events(:ready_listing), data: { "event_id" => events_events(:ready_listing).id },
        dedupe_key: "read-test-#{SecureRandom.uuid}", retention_policy: policy,
        retain_until: policy.retention_days && policy.retention_days.days.from_now,
        available_at: Time.current
      )
    end
  end
end
