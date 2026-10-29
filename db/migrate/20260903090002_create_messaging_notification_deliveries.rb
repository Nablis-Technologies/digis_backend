# frozen_string_literal: true

class CreateMessagingNotificationDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_notification_deliveries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :notification_id, null: false
      t.string :channel, null: false
      t.string :status, null: false, default: "pending"
      t.string :provider
      t.string :provider_message_id
      t.integer :attempts, null: false, default: 0
      t.string :idempotency_key_digest, null: false, limit: 64
      t.timestamptz :next_attempt_at
      t.timestamptz :claimed_at
      t.timestamptz :enqueue_claimed_at
      t.timestamptz :scheduled_at
      t.timestamptz :sent_at
      t.timestamptz :delivered_at
      t.timestamptz :failed_at
      t.string :failure_code
      t.text :failure_detail

      t.timestamps
    end

    add_check_constraint :messaging_notification_deliveries,
      "channel IN ('in_app','email','sms')",
      name: "messaging_notification_deliveries_channel_check"
    add_check_constraint :messaging_notification_deliveries,
      "status IN ('pending','processing','sent','delivered','failed','suppressed','unavailable')",
      name: "messaging_notification_deliveries_status_check"
    add_check_constraint :messaging_notification_deliveries,
      "attempts >= 0",
      name: "messaging_notification_deliveries_attempts_check"
    add_check_constraint :messaging_notification_deliveries,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_notification_deliveries_digest_check"

    add_index :messaging_notification_deliveries,
      %i[notification_id channel], unique: true,
      name: "idx_messaging_notification_deliveries_notification_channel"
    add_index :messaging_notification_deliveries,
      %i[status next_attempt_at enqueue_claimed_at scheduled_at id],
      where: "status IN ('pending','processing')",
      name: "idx_messaging_notification_deliveries_claimable"
    add_index :messaging_notification_deliveries, :provider_message_id,
      unique: true,
      where: "provider_message_id IS NOT NULL",
      name: "idx_messaging_notification_deliveries_provider_message"

    add_foreign_key :messaging_notification_deliveries,
      :messaging_notifications, column: :notification_id, on_delete: :cascade
  end
end
