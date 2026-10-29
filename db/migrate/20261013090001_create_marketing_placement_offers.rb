# frozen_string_literal: true

class CreateMarketingPlacementOffers < ActiveRecord::Migration[8.1]
  def change
    create_table :marketing_placement_offers, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :code, null: false
      t.integer :version, null: false
      t.bigint :daily_rate_minor, null: false
      t.string :currency, limit: 3, null: false
      t.integer :minimum_duration_seconds, null: false
      t.integer :maximum_duration_seconds, null: false
      t.string :surface, null: false
      t.string :terms_version, null: false
      t.string :status, null: false, default: "draft"
      t.timestamptz :starts_at, null: false
      t.timestamptz :ends_at, null: false
      t.references :created_by, type: :uuid, null: false, foreign_key: { to_table: :core_users }
      t.references :activated_by, type: :uuid, foreign_key: { to_table: :core_users }
      t.references :retired_by, type: :uuid, foreign_key: { to_table: :core_users }
      t.timestamptz :activated_at
      t.timestamptz :retired_at
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :request_digest, limit: 64, null: false

      t.timestamps
    end

    add_index :marketing_placement_offers, %i[code version], unique: true
    add_index :marketing_placement_offers, :idempotency_key_digest, unique: true,
      name: "idx_marketing_placement_offers_idempotency_digest"
    add_index :marketing_placement_offers, %i[surface starts_at ends_at],
      where: "status = 'active'", name: "idx_marketing_placement_offers_active_window"

    add_check_constraint :marketing_placement_offers,
      "btrim(code) <> '' AND version > 0 AND btrim(terms_version) <> ''",
      name: "marketing_placement_offers_identity_check"
    add_check_constraint :marketing_placement_offers,
      "daily_rate_minor > 0 AND currency = 'ETB'",
      name: "marketing_placement_offers_price_check"
    add_check_constraint :marketing_placement_offers,
      "minimum_duration_seconds >= 86400 AND maximum_duration_seconds >= minimum_duration_seconds " \
      "AND maximum_duration_seconds <= 1209600",
      name: "marketing_placement_offers_duration_check"
    add_check_constraint :marketing_placement_offers,
      "surface = 'public_discovery' AND ends_at > starts_at",
      name: "marketing_placement_offers_surface_window_check"
    add_check_constraint :marketing_placement_offers,
      "status IN ('draft', 'active', 'retired')",
      name: "marketing_placement_offers_status_check"
    add_check_constraint :marketing_placement_offers,
      "((status = 'draft' AND activated_by_id IS NULL AND activated_at IS NULL AND retired_by_id IS NULL AND retired_at IS NULL) " \
      "OR (status = 'active' AND activated_by_id IS NOT NULL AND activated_at IS NOT NULL AND retired_by_id IS NULL AND retired_at IS NULL) " \
      "OR (status = 'retired' AND retired_by_id IS NOT NULL AND retired_at IS NOT NULL " \
      "AND ((activated_by_id IS NULL AND activated_at IS NULL) OR (activated_by_id IS NOT NULL AND activated_at IS NOT NULL))))",
      name: "marketing_placement_offers_lifecycle_check"
    add_check_constraint :marketing_placement_offers,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND request_digest ~ '^[0-9a-f]{64}$'",
      name: "marketing_placement_offers_digest_check"
  end
end
