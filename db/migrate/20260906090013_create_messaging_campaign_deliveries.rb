# frozen_string_literal: true

class CreateMessagingCampaignDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_deliveries, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :campaign_id, null: false
      t.uuid :campaign_recipient_id, null: false
      t.string :channel, null: false
      t.string :status, null: false, default: "pending"
      t.string :provider
      t.string :provider_message_id
      t.integer :attempts, null: false, default: 0
      t.string :idempotency_key_digest, limit: 64, null: false
      t.timestamptz :next_attempt_at
      t.timestamptz :claimed_at
      t.timestamptz :sent_at
      t.timestamptz :delivered_at
      t.timestamptz :failed_at
      t.string :failure_code
      t.text :failure_detail

      t.timestamps
    end

    add_check_constraint :messaging_campaign_deliveries,
      "channel IN ('sms','email')",
      name: "messaging_campaign_deliveries_channel_check"
    add_check_constraint :messaging_campaign_deliveries,
      "status IN ('pending','processing','sent','delivered','failed','suppressed','unavailable')",
      name: "messaging_campaign_deliveries_status_check"
    add_check_constraint :messaging_campaign_deliveries,
      "attempts >= 0 AND idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_campaign_deliveries_identity_check"

    add_index :messaging_campaign_deliveries,
      %i[campaign_id campaign_recipient_id], unique: true,
      name: "idx_messaging_campaign_deliveries_recipient"
    add_index :messaging_campaign_deliveries,
      %i[status next_attempt_at claimed_at id],
      where: "status IN ('pending','processing')",
      name: "idx_messaging_campaign_deliveries_claimable"
    add_index :messaging_campaign_deliveries, :provider_message_id,
      unique: true, where: "provider_message_id IS NOT NULL",
      name: "idx_messaging_campaign_deliveries_provider_message"
    add_foreign_key :messaging_campaign_deliveries,
      :messaging_campaigns, column: :campaign_id, on_delete: :cascade
    add_foreign_key :messaging_campaign_deliveries,
      :messaging_campaign_recipients, column: :campaign_recipient_id, on_delete: :cascade
  end
end
