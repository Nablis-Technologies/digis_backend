# frozen_string_literal: true

class CreateMarketingFeaturedPlacements < ActiveRecord::Migration[8.1]
  def change
    create_table :marketing_featured_placements, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :organization_id, null: false
      t.uuid :placement_offer_id, null: false
      t.uuid :refund_id
      t.string :status, null: false, default: "pending_payment"
      t.string :surface, null: false
      t.timestamptz :starts_at, null: false
      t.timestamptz :ends_at, null: false
      t.integer :duration_seconds, null: false
      t.string :offer_code, null: false
      t.integer :offer_version, null: false
      t.bigint :daily_rate_minor, null: false
      t.bigint :amount_minor, null: false
      t.string :currency, limit: 3, null: false
      t.string :terms_version, null: false
      t.string :price_digest, limit: 64, null: false
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :request_digest, limit: 64, null: false
      t.string :failure_code
      t.timestamptz :cancelled_at
      t.timestamptz :completed_at

      t.timestamps
    end

    add_index :marketing_featured_placements, %i[organization_id idempotency_key_digest], unique: true,
      name: "idx_marketing_featured_placements_idempotency"
    add_index :marketing_featured_placements, %i[event_id status starts_at ends_at],
      name: "idx_marketing_featured_placements_event_window"
    add_index :marketing_featured_placements, %i[surface status starts_at ends_at],
      name: "idx_marketing_featured_placements_surface_window"
    add_index :marketing_featured_placements, :refund_id, unique: true,
      where: "refund_id IS NOT NULL"

    add_check_constraint :marketing_featured_placements,
      "status IN ('pending_payment','scheduled','active','completed','cancelled','failed')",
      name: "marketing_featured_placements_status_check"
    add_check_constraint :marketing_featured_placements,
      "surface = 'public_discovery' AND ends_at > starts_at AND duration_seconds = " \
      "FLOOR(EXTRACT(EPOCH FROM (ends_at - starts_at)))::integer",
      name: "marketing_featured_placements_window_check"
    add_check_constraint :marketing_featured_placements,
      "duration_seconds BETWEEN 86400 AND 1209600 AND daily_rate_minor > 0 AND amount_minor > 0 " \
      "AND amount_minor = CEIL(daily_rate_minor::numeric * duration_seconds / 86400)::bigint " \
      "AND currency = 'ETB' AND offer_version > 0 AND btrim(offer_code) <> '' " \
      "AND btrim(terms_version) <> ''",
      name: "marketing_featured_placements_price_snapshot_check"
    add_check_constraint :marketing_featured_placements,
      "price_digest ~ '^[0-9a-f]{64}$' AND idempotency_key_digest ~ '^[0-9a-f]{64}$' " \
      "AND request_digest ~ '^[0-9a-f]{64}$'",
      name: "marketing_featured_placements_digest_check"

    add_foreign_key :marketing_featured_placements, :events_events, column: :event_id, on_delete: :restrict
    add_foreign_key :marketing_featured_placements, :organizations_organizations,
      column: :organization_id, on_delete: :restrict
    add_foreign_key :marketing_featured_placements, :marketing_placement_offers,
      column: :placement_offer_id, on_delete: :restrict
    add_foreign_key :marketing_featured_placements, :orders_refunds, column: :refund_id, on_delete: :restrict
  end
end
