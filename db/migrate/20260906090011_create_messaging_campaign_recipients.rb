# frozen_string_literal: true

class CreateMessagingCampaignRecipients < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_recipients, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :campaign_id, null: false
      t.uuid :audience_snapshot_id, null: false
      t.string :channel, null: false
      t.string :channel_address_digest, limit: 64, null: false
      t.text :channel_address_ciphertext
      t.text :first_name_ciphertext
      t.text :last_name_ciphertext
      t.string :source_type, null: false
      t.uuid :source_id
      t.string :historical_basis
      t.string :eligibility_status, null: false, default: "eligible"
      t.string :eligibility_reason
      t.bigint :quantity, null: false, default: 1

      t.timestamps
    end

    add_check_constraint :messaging_campaign_recipients,
      "channel IN ('sms','email')",
      name: "messaging_campaign_recipients_channel_check"
    add_check_constraint :messaging_campaign_recipients,
      "channel_address_digest ~ '^[0-9a-f]{64}$' AND quantity > 0",
      name: "messaging_campaign_recipients_identity_check"
    add_check_constraint :messaging_campaign_recipients,
      "source_type IN ('event','ticket','registration','organization_subscriber','contact_list')",
      name: "messaging_campaign_recipients_source_check"
    add_check_constraint :messaging_campaign_recipients,
      "eligibility_status IN ('eligible','suppressed','invalid','missing_channel')",
      name: "messaging_campaign_recipients_eligibility_check"
    add_check_constraint :messaging_campaign_recipients,
      "source_id IS NOT NULL OR source_type = 'contact_list'",
      name: "messaging_campaign_recipients_source_id_check"

    add_index :messaging_campaign_recipients,
      %i[campaign_id channel_address_digest], unique: true,
      name: "idx_messaging_campaign_recipients_dedupe"
    add_index :messaging_campaign_recipients,
      %i[audience_snapshot_id id], name: "idx_messaging_campaign_recipients_snapshot"
    add_foreign_key :messaging_campaign_recipients,
      :messaging_campaigns, column: :campaign_id, on_delete: :cascade
    add_foreign_key :messaging_campaign_recipients,
      :messaging_campaign_audience_snapshots, column: :audience_snapshot_id, on_delete: :cascade
  end
end
