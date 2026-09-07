# frozen_string_literal: true

class CreateMessagingCampaignInboundEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_inbound_events, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :provider, null: false
      t.string :external_event_id, null: false
      t.string :payload_digest, limit: 64, null: false
      t.string :status, null: false, default: "received"
      t.timestamptz :received_at, null: false
      t.timestamptz :processed_at

      t.timestamps
    end

    add_check_constraint :messaging_campaign_inbound_events,
      "payload_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_campaign_inbound_events_digest_check"
    add_check_constraint :messaging_campaign_inbound_events,
      "status IN ('received','processed','ignored','failed')",
      name: "messaging_campaign_inbound_events_status_check"
    add_index :messaging_campaign_inbound_events,
      %i[provider external_event_id], unique: true,
      name: "idx_messaging_campaign_inbound_events_identity"
  end
end
