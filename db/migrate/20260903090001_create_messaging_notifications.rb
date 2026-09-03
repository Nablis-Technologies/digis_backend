# frozen_string_literal: true

class CreateMessagingNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_notifications, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :user_id, null: false
      t.string :notification_type, null: false
      t.string :category, null: false
      t.string :source_type
      t.uuid :source_id
      t.jsonb :data, null: false, default: {}
      t.string :projection_digest, null: false, limit: 64
      t.string :dedupe_key, null: false
      t.uuid :retention_policy_id, null: false
      t.timestamptz :retain_until
      t.timestamptz :available_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :read_at
      t.timestamptz :erased_at
      t.string :erasure_reason

      t.timestamps
    end

    add_check_constraint :messaging_notifications,
      "category IN ('transactional','security','credential','legal')",
      name: "messaging_notifications_category_check"
    add_check_constraint :messaging_notifications,
      "jsonb_typeof(data) = 'object'",
      name: "messaging_notifications_data_object_check"
    add_check_constraint :messaging_notifications,
      "projection_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_notifications_projection_digest_check"
    add_check_constraint :messaging_notifications,
      "source_type IS NULL OR source_type IN " \
        "('Orders::Order','Orders::Payment','Orders::Refund','Ticketing::Ticket'," \
        "'Ticketing::TicketTransfer','Ticketing::Registration'," \
        "'Ticketing::RegistrationConsentRequirement','Events::Event')",
      name: "messaging_notifications_source_type_check"
    add_check_constraint :messaging_notifications,
      "retain_until IS NULL OR retain_until > created_at",
      name: "messaging_notifications_retention_window_check"
    add_check_constraint :messaging_notifications,
      "(erased_at IS NULL AND erasure_reason IS NULL) OR " \
        "(erased_at IS NOT NULL AND erasure_reason IS NOT NULL)",
      name: "messaging_notifications_erasure_check"

    add_index :messaging_notifications, %i[user_id dedupe_key],
      unique: true, name: "idx_messaging_notifications_user_dedupe"
    add_index :messaging_notifications, %i[user_id read_at available_at id],
      where: "erased_at IS NULL",
      name: "idx_messaging_notifications_inbox"
    add_index :messaging_notifications, %i[source_type source_id],
      name: "idx_messaging_notifications_source"
    add_index :messaging_notifications, %i[retention_policy_id retain_until],
      name: "idx_messaging_notifications_retention"

    add_foreign_key :messaging_notifications, :core_users,
      column: :user_id, on_delete: :restrict
    add_foreign_key :messaging_notifications, :core_data_retention_policies,
      column: :retention_policy_id, on_delete: :restrict
  end
end
