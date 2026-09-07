# frozen_string_literal: true

class CreateMessagingCampaignVolumePolicies < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaign_volume_policies, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id
      t.string :channel, null: false
      t.string :timezone, null: false
      t.bigint :daily_limit, null: false
      t.bigint :monthly_limit, null: false
      t.boolean :active, null: false, default: true
      t.uuid :updated_by_id
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :request_digest, limit: 64, null: false

      t.timestamps
    end

    add_check_constraint :messaging_campaign_volume_policies,
      "channel IN ('sms','email')",
      name: "messaging_campaign_volume_policies_channel_check"
    add_check_constraint :messaging_campaign_volume_policies,
      "daily_limit > 0 AND monthly_limit >= daily_limit",
      name: "messaging_campaign_volume_policies_limits_check"
    add_check_constraint :messaging_campaign_volume_policies,
      "timezone <> ''",
      name: "messaging_campaign_volume_policies_timezone_check"
    add_check_constraint :messaging_campaign_volume_policies,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND request_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_campaign_volume_policies_digest_check"

    add_index :messaging_campaign_volume_policies,
      %i[organization_id channel], unique: true, nulls_not_distinct: true,
      name: "idx_messaging_campaign_volume_policies_scope"
    add_foreign_key :messaging_campaign_volume_policies,
      :organizations_organizations, column: :organization_id, on_delete: :restrict
    add_foreign_key :messaging_campaign_volume_policies, :core_users,
      column: :updated_by_id, on_delete: :restrict
  end
end
