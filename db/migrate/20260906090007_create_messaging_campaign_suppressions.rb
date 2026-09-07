# frozen_string_literal: true

class CreateMessagingCampaignSuppressions < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_suppressions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id
      t.string :channel, null: false
      t.string :channel_address_digest, limit: 64, null: false
      t.string :source, null: false
      t.string :reason, null: false
      t.timestamptz :suppressed_at, null: false
      t.string :idempotency_key_digest, limit: 64, null: false

      t.timestamps
    end

    add_check_constraint :messaging_campaign_suppressions,
      "channel IN ('sms','email')",
      name: "messaging_campaign_suppressions_channel_check"
    add_check_constraint :messaging_campaign_suppressions,
      "channel_address_digest ~ '^[0-9a-f]{64}$' AND idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_campaign_suppressions_digest_check"

    add_index :messaging_campaign_suppressions,
      %i[organization_id channel channel_address_digest], unique: true,
      nulls_not_distinct: true,
      name: "idx_messaging_campaign_suppressions_scope"
    add_index :messaging_campaign_suppressions, :idempotency_key_digest,
      unique: true, name: "idx_messaging_campaign_suppressions_idempotency"
    add_foreign_key :messaging_campaign_suppressions,
      :organizations_organizations, column: :organization_id, on_delete: :restrict
  end
end
