# frozen_string_literal: true

class CreateMessagingCampaignContactListImports < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_contact_list_imports, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :campaign_contact_list_id, null: false
      t.uuid :created_by_id, null: false
      t.string :status, null: false, default: "pending"
      t.string :filename
      t.integer :total_rows, null: false, default: 0
      t.integer :accepted_rows, null: false, default: 0
      t.integer :duplicate_rows, null: false, default: 0
      t.integer :invalid_rows, null: false, default: 0
      t.integer :suppressed_rows, null: false, default: 0
      t.integer :missing_channel_rows, null: false, default: 0
      t.text :error_detail
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :request_digest, limit: 64, null: false
      t.timestamptz :started_at
      t.timestamptz :completed_at

      t.timestamps
    end

    add_check_constraint :messaging_campaign_contact_list_imports,
      "status IN ('pending','processing','completed','failed')",
      name: "messaging_campaign_contact_list_imports_status_check"
    add_check_constraint :messaging_campaign_contact_list_imports,
      "total_rows >= 0 AND accepted_rows >= 0 AND duplicate_rows >= 0 AND " \
      "invalid_rows >= 0 AND suppressed_rows >= 0 AND missing_channel_rows >= 0",
      name: "messaging_campaign_contact_list_imports_counts_check"
    add_check_constraint :messaging_campaign_contact_list_imports,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND request_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_campaign_contact_list_imports_digest_check"

    add_index :messaging_campaign_contact_list_imports,
      %i[campaign_contact_list_id idempotency_key_digest], unique: true,
      name: "idx_messaging_campaign_contact_list_imports_idempotency"
    add_index :messaging_campaign_contact_list_imports,
      %i[status created_at id],
      where: "status IN ('pending','processing')",
      name: "idx_messaging_campaign_contact_list_imports_pending"
    add_foreign_key :messaging_campaign_contact_list_imports,
      :messaging_campaign_contact_lists, column: :campaign_contact_list_id, on_delete: :cascade
    add_foreign_key :messaging_campaign_contact_list_imports, :core_users,
      column: :created_by_id, on_delete: :restrict
  end
end
