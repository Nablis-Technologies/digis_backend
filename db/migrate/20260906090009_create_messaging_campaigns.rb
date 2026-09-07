# frozen_string_literal: true

class CreateMessagingCampaigns < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_campaigns, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :created_by_id, null: false
      t.uuid :event_id
      t.uuid :campaign_template_version_id
      t.string :name, null: false
      t.string :channel, null: false
      t.string :status, null: false, default: "draft"
      t.string :timezone, null: false
      t.integer :launch_version, null: false, default: 1
      t.timestamptz :send_at
      t.timestamptz :launched_at
      t.timestamptz :completed_at
      t.timestamptz :canceled_at
      t.bigint :quoted_quantity
      t.uuid :quoted_rate_version_id
      t.bigint :quoted_unit_price_minor
      t.string :quote_digest, limit: 64
      t.timestamptz :quoted_at
      t.timestamptz :quote_expires_at
      t.text :message_subject_ciphertext
      t.text :message_body_ciphertext
      t.jsonb :variables, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_check_constraint :messaging_campaigns,
      "channel IN ('sms','email')",
      name: "messaging_campaigns_channel_check"
    add_check_constraint :messaging_campaigns,
      "status IN ('draft','scheduled','sending','paused','canceled','completed','failed')",
      name: "messaging_campaigns_status_check"
    add_check_constraint :messaging_campaigns,
      "timezone <> '' AND launch_version > 0",
      name: "messaging_campaigns_identity_check"
    add_check_constraint :messaging_campaigns,
      "(quote_digest IS NULL OR quote_digest ~ '^[0-9a-f]{64}$')",
      name: "messaging_campaigns_quote_digest_check"
    add_check_constraint :messaging_campaigns,
      "(quoted_at IS NULL AND quote_expires_at IS NULL) OR " \
      "(quoted_at IS NOT NULL AND quote_expires_at > quoted_at)",
      name: "messaging_campaigns_quote_window_check"
    add_check_constraint :messaging_campaigns,
      "(quoted_rate_version_id IS NULL AND quoted_quantity IS NULL AND quoted_unit_price_minor IS NULL AND quote_digest IS NULL AND " \
      "quoted_at IS NULL AND quote_expires_at IS NULL) OR " \
      "(quoted_rate_version_id IS NOT NULL AND quoted_quantity IS NOT NULL AND quoted_unit_price_minor IS NOT NULL AND " \
      "quoted_unit_price_minor > 0 AND quote_digest IS NOT NULL AND " \
      "quoted_at IS NOT NULL AND quote_expires_at IS NOT NULL AND quoted_quantity > 0)",
      name: "messaging_campaigns_quote_completeness_check"
    add_check_constraint :messaging_campaigns,
      "jsonb_typeof(variables) = 'object' AND jsonb_typeof(metadata) = 'object'",
      name: "messaging_campaigns_json_check"
    add_check_constraint :messaging_campaigns,
      "completed_at IS NULL OR status = 'completed'",
      name: "messaging_campaigns_completed_at_check"
    add_check_constraint :messaging_campaigns,
      "canceled_at IS NULL OR status = 'canceled'",
      name: "messaging_campaigns_canceled_at_check"

    add_index :messaging_campaigns, %i[organization_id status send_at id],
      name: "idx_messaging_campaigns_schedule"
    add_index :messaging_campaigns, %i[organization_id name],
      unique: true, name: "idx_messaging_campaigns_name"
    add_foreign_key :messaging_campaigns, :organizations_organizations,
      column: :organization_id, on_delete: :restrict
    add_foreign_key :messaging_campaigns, :core_users,
      column: :created_by_id, on_delete: :restrict
    add_foreign_key :messaging_campaigns, :events_events,
      column: :event_id, on_delete: :restrict
    add_foreign_key :messaging_campaigns, :messaging_campaign_template_versions,
      column: :campaign_template_version_id, on_delete: :restrict
    add_foreign_key :messaging_campaigns, :messaging_credit_rate_versions,
      column: :quoted_rate_version_id, on_delete: :restrict
  end
end
