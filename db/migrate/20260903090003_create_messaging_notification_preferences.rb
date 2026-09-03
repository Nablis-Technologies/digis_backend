# frozen_string_literal: true

class CreateMessagingNotificationPreferences < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_notification_preferences, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :user_id, null: false
      t.string :category, null: false
      t.string :channel, null: false
      t.boolean :enabled, null: false, default: true

      t.timestamps
    end

    add_check_constraint :messaging_notification_preferences,
      "category IN ('transactional','security','credential','legal')",
      name: "messaging_notification_preferences_category_check"
    add_check_constraint :messaging_notification_preferences,
      "channel IN ('in_app','email','sms')",
      name: "messaging_notification_preferences_channel_check"

    add_index :messaging_notification_preferences,
      %i[user_id category channel], unique: true,
      name: "idx_messaging_notification_preferences_scope"
    add_foreign_key :messaging_notification_preferences, :core_users,
      column: :user_id, on_delete: :cascade
  end
end
