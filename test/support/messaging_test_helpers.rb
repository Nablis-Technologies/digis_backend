# frozen_string_literal: true

# Shared fixtures for Messaging service/job tests. The helper keeps the
# notification source and retention policy valid without seeding provider data.
module MessagingTestHelpers
  def create_messaging_policy(action: "erase_payload", retention_days: 365, version: 1)
    Core::DataRetentionPolicy.create!(
      category: "messaging_notification",
      version:,
      action:,
      retention_days:,
      status: "active",
      effective_at: 1.day.ago,
      created_by: core_users(:super_admin)
    )
  end

  def create_messaging_notification(user: core_users(:attendee), type: "schedule_changed", dedupe_key: SecureRandom.uuid)
    policy = Core::DataRetentionPolicy.active.find_by!(category: "messaging_notification")
    event = events_events(:ready_listing)
    data = { "event_id" => event.id, "schedule_version" => 1, "event_date_ids" => [] }
    Messaging::Notification.create!(
      user:, notification_type: type, category: Messaging::NotificationTypes.fetch(type).category,
      source: event, data:, dedupe_key:, retention_policy: policy,
      retain_until: policy.retention_days && policy.retention_days.days.from_now,
      available_at: Time.current
    )
  end

  def create_messaging_delivery(notification:, channel: "in_app", status: "pending")
    Messaging::NotificationDelivery.create!(
      notification:, channel:, status:,
      idempotency_key_digest: Core::KeyedDigest.digest(
        namespace: "messaging-notification-delivery-test", value: "#{notification.id}:#{channel}"
      ),
      scheduled_at: notification.available_at
    )
  end
end

ActiveSupport::TestCase.include(MessagingTestHelpers)
