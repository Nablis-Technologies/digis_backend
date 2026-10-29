# frozen_string_literal: true

require "test_helper"

module Messaging
  class PublishNotificationTest < ActiveSupport::TestCase
    setup do
      @user = core_users(:attendee)
      @event = events_events(:ready_listing)
      @policy = Core::DataRetentionPolicy.create!(
        category: "messaging_notification",
        version: 1,
        action: "erase_payload",
        retention_days: 365,
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )
    end

    test "publishes one notification and one delivery per registered channel" do
      result = Messaging::PublishNotification.call(
        type: "schedule_changed",
        recipient: @user,
        source: @event,
        data: { event_id: @event.id, schedule_version: 2, event_date_ids: [] },
        dedupe_key: "schedule-changed:#{@event.id}:v2"
      )

      assert_predicate result, :success?, result.error&.message
      notification = result.value
      assert_equal @policy.id, notification.retention_policy_id
      assert_in_delta 365.days.from_now.to_f, notification.retain_until.to_f, 2.seconds
      assert_equal %w[email in_app sms], notification.deliveries.order(:channel).pluck(:channel)
      assert_equal %w[pending pending pending], notification.deliveries.order(:channel).pluck(:status)
    end

    test "replaying an identical notification is idempotent" do
      subject = -> do
        Messaging::PublishNotification.call(
          type: "schedule_changed",
          recipient: @user,
          source: @event,
          data: { event_id: @event.id, schedule_version: 2, event_date_ids: [] },
          dedupe_key: "schedule-changed:#{@event.id}:v2"
        )
      end

      assert_idempotent(subject, counter: -> { Messaging::Notification.where(user: @user).count })
      assert_equal 3, Messaging::Notification.where(user: @user).first.deliveries.count
    end

    test "treats equivalent projections with different key order as the same replay" do
      first = Messaging::PublishNotification.call(
        type: "schedule_changed", recipient: @user, source: @event,
        data: { event_id: @event.id, schedule_version: 2, event_date_ids: [] },
        dedupe_key: "schedule-changed:#{@event.id}:v2"
      )
      replay = Messaging::PublishNotification.call(
        type: "schedule_changed", recipient: @user, source: @event,
        data: { event_date_ids: [], schedule_version: 2, event_id: @event.id },
        dedupe_key: "schedule-changed:#{@event.id}:v2"
      )

      # The shared idempotency assertion cannot express a replay with a
      # reordered request, so assert the persisted identity explicitly here.
      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert_equal first.value.id, replay.value.id
    end

    test "a different payload under the same dedupe key fails closed" do
      first = Messaging::PublishNotification.call(
        type: "schedule_changed", recipient: @user, source: @event,
        data: { event_id: @event.id, schedule_version: 2, event_date_ids: [] },
        dedupe_key: "schedule-changed:#{@event.id}:v2"
      )
      assert_predicate first, :success?

      conflict = Messaging::PublishNotification.call(
        type: "schedule_changed", recipient: @user, source: @event,
        data: { event_id: @event.id, schedule_version: 3, event_date_ids: [] },
        dedupe_key: "schedule-changed:#{@event.id}:v2"
      )

      assert_predicate conflict, :failure?
      assert_equal "notification_idempotency_conflict", conflict.error.code
    end

    test "detects conflicting replay after the payload was erased" do
      data = { event_id: @event.id, schedule_version: 6, event_date_ids: [] }
      first = Messaging::PublishNotification.call(
        type: "schedule_changed", recipient: @user, source: @event,
        data:, dedupe_key: "schedule-changed:#{@event.id}:v6"
      )
      notification = first.value
      digest = notification.projection_digest
      notification.update_columns(data: {}, erased_at: Time.current, erasure_reason: "policy_expiry")

      replay = Messaging::PublishNotification.call(
        type: "schedule_changed", recipient: @user, source: @event,
        data:, dedupe_key: "schedule-changed:#{@event.id}:v6"
      )
      conflict = Messaging::PublishNotification.call(
        type: "schedule_changed", recipient: @user, source: @event,
        data: data.merge(schedule_version: 7), dedupe_key: "schedule-changed:#{@event.id}:v6"
      )

      assert_predicate replay, :success?, replay.error&.message
      assert_predicate conflict, :failure?
      assert_equal "notification_idempotency_conflict", conflict.error.code
      assert_equal digest, notification.reload.projection_digest
    end

    test "a disabled optional channel is recorded as suppressed" do
      NotificationPreference.create!(user: @user, category: "transactional", channel: "email", enabled: false)

      result = Messaging::PublishNotification.call(
        type: "schedule_changed", recipient: @user, source: @event,
        data: { event_id: @event.id, schedule_version: 4, event_date_ids: [] },
        dedupe_key: "schedule-changed:#{@event.id}:v4"
      )

      assert_predicate result, :success?
      assert_equal "suppressed", result.value.deliveries.find_by!(channel: "email").status
      assert_equal "pending", result.value.deliveries.find_by!(channel: "in_app").status
    end

    test "a retain policy leaves retain_until null" do
      @policy.update!(status: "retired")
      Core::DataRetentionPolicy.create!(
        category: "messaging_notification",
        version: 2,
        action: "retain",
        retention_days: nil,
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )

      result = Messaging::PublishNotification.call(
        type: "schedule_changed", recipient: @user, source: @event,
        data: { event_id: @event.id, schedule_version: 5, event_date_ids: [] },
        dedupe_key: "schedule-changed:#{@event.id}:v5"
      )

      assert_predicate result, :success?
      assert_nil result.value.retain_until
    end
  end
end
