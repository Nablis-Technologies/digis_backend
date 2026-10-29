# frozen_string_literal: true

class CreateMessagingCampaignAttestations < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_attestations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :campaign_id, null: false
      t.uuid :audience_snapshot_id, null: false
      t.uuid :actor_id, null: false
      t.string :channel, null: false
      t.string :historical_basis
      t.integer :statement_version, null: false, default: 1
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :request_digest, limit: 64, null: false
      t.timestamptz :attested_at, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_check_constraint :messaging_campaign_attestations,
      "channel IN ('sms','email') AND statement_version > 0",
      name: "messaging_campaign_attestations_identity_check"
    add_check_constraint :messaging_campaign_attestations,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND request_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_campaign_attestations_digest_check"
    add_check_constraint :messaging_campaign_attestations,
      "jsonb_typeof(metadata) = 'object'",
      name: "messaging_campaign_attestations_metadata_check"

    add_index :messaging_campaign_attestations,
      %i[campaign_id idempotency_key_digest], unique: true,
      name: "idx_messaging_campaign_attestations_idempotency"
    add_foreign_key :messaging_campaign_attestations,
      :messaging_campaigns, column: :campaign_id, on_delete: :cascade
    add_foreign_key :messaging_campaign_attestations,
      :messaging_campaign_audience_snapshots, column: :audience_snapshot_id, on_delete: :cascade
    add_foreign_key :messaging_campaign_attestations, :core_users,
      column: :actor_id, on_delete: :restrict
  end
end
