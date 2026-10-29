# frozen_string_literal: true

class CreateMessagingCreditRateVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :messaging_credit_rate_versions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :organization_id
      t.string :channel, null: false
      t.integer :version, null: false
      t.string :currency, limit: 3, null: false
      t.bigint :unit_price_minor, null: false
      t.bigint :provider_cost_minor
      t.string :country_code, limit: 2
      t.jsonb :volume_tiers, null: false, default: []
      t.timestamptz :effective_from, null: false
      t.timestamptz :effective_until
      t.string :status, null: false, default: "draft"
      t.uuid :created_by_id
      t.uuid :activated_by_id
      t.uuid :retired_by_id
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :request_digest, limit: 64, null: false
      t.timestamptz :activated_at
      t.timestamptz :retired_at

      t.timestamps
    end

    add_check_constraint :messaging_credit_rate_versions,
      "channel IN ('sms','email')",
      name: "messaging_credit_rate_versions_channel_check"
    add_check_constraint :messaging_credit_rate_versions,
      "version > 0",
      name: "messaging_credit_rate_versions_version_check"
    add_check_constraint :messaging_credit_rate_versions,
      "currency ~ '^[A-Z]{3}$'",
      name: "messaging_credit_rate_versions_currency_check"
    add_check_constraint :messaging_credit_rate_versions,
      "unit_price_minor > 0 AND (provider_cost_minor IS NULL OR provider_cost_minor >= 0)",
      name: "messaging_credit_rate_versions_amount_check"
    add_check_constraint :messaging_credit_rate_versions,
      "country_code IS NULL OR country_code ~ '^[A-Z]{2}$'",
      name: "messaging_credit_rate_versions_country_check"
    add_check_constraint :messaging_credit_rate_versions,
      "jsonb_typeof(volume_tiers) = 'array'",
      name: "messaging_credit_rate_versions_volume_tiers_check"
    add_check_constraint :messaging_credit_rate_versions,
      "status IN ('draft','active','retired')",
      name: "messaging_credit_rate_versions_status_check"
    add_check_constraint :messaging_credit_rate_versions,
      "effective_until IS NULL OR effective_until > effective_from",
      name: "messaging_credit_rate_versions_effective_window_check"
    add_check_constraint :messaging_credit_rate_versions,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND request_digest ~ '^[0-9a-f]{64}$'",
      name: "messaging_credit_rate_versions_request_check"
    add_check_constraint :messaging_credit_rate_versions,
      "(status = 'draft' AND activated_at IS NULL AND retired_at IS NULL) OR " \
      "(status = 'active' AND activated_at IS NOT NULL AND retired_at IS NULL) OR " \
      "(status = 'retired' AND activated_at IS NOT NULL AND retired_at IS NOT NULL)",
      name: "messaging_credit_rate_versions_state_check"

    add_index :messaging_credit_rate_versions,
      %i[organization_id channel currency country_code version],
      unique: true,
      nulls_not_distinct: true,
      name: "idx_messaging_credit_rates_scope_version"
    add_index :messaging_credit_rate_versions, %i[channel country_code status effective_from],
      name: "idx_messaging_credit_rates_resolution"

    add_foreign_key :messaging_credit_rate_versions, :organizations_organizations,
      column: :organization_id, on_delete: :restrict
    add_foreign_key :messaging_credit_rate_versions, :core_users,
      column: :created_by_id, on_delete: :restrict
    add_foreign_key :messaging_credit_rate_versions, :core_users,
      column: :activated_by_id, on_delete: :restrict
    add_foreign_key :messaging_credit_rate_versions, :core_users,
      column: :retired_by_id, on_delete: :restrict
  end
end
