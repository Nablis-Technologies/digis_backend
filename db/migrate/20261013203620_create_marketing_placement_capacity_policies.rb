# frozen_string_literal: true

class CreateMarketingPlacementCapacityPolicies < ActiveRecord::Migration[8.1]
  def change
    create_table :marketing_placement_capacity_policies, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :surface, null: false
      t.integer :version, null: false
      t.integer :max_concurrent, null: false
      t.string :status, null: false, default: "draft"
      t.timestamptz :effective_from, null: false
      t.timestamptz :effective_until
      t.references :created_by, type: :uuid, null: false, foreign_key: { to_table: :core_users }
      t.references :activated_by, type: :uuid, foreign_key: { to_table: :core_users }
      t.references :retired_by, type: :uuid, foreign_key: { to_table: :core_users }
      t.timestamptz :activated_at
      t.timestamptz :retired_at
      t.string :idempotency_key_digest, limit: 64, null: false
      t.string :request_digest, limit: 64, null: false

      t.timestamps
    end

    add_index :marketing_placement_capacity_policies, %i[surface version], unique: true,
      name: "idx_marketing_capacity_policies_surface_version"
    add_index :marketing_placement_capacity_policies, :idempotency_key_digest, unique: true,
      name: "idx_marketing_capacity_policies_idempotency_digest"
    add_index :marketing_placement_capacity_policies, %i[surface effective_from],
      where: "status = 'active'", name: "idx_marketing_capacity_policies_active_resolution"

    add_check_constraint :marketing_placement_capacity_policies,
      "surface = 'public_discovery' AND version > 0",
      name: "marketing_capacity_policies_identity_check"
    add_check_constraint :marketing_placement_capacity_policies,
      "max_concurrent BETWEEN 1 AND 100",
      name: "marketing_capacity_policies_limit_check"
    add_check_constraint :marketing_placement_capacity_policies,
      "effective_until IS NULL OR effective_until > effective_from",
      name: "marketing_capacity_policies_window_check"
    add_check_constraint :marketing_placement_capacity_policies,
      "status IN ('draft', 'active', 'retired')",
      name: "marketing_capacity_policies_status_check"
    add_check_constraint :marketing_placement_capacity_policies,
      "((status = 'draft' AND activated_by_id IS NULL AND activated_at IS NULL AND retired_by_id IS NULL AND retired_at IS NULL) " \
      "OR (status = 'active' AND activated_by_id IS NOT NULL AND activated_at IS NOT NULL AND retired_by_id IS NULL AND retired_at IS NULL) " \
      "OR (status = 'retired' AND retired_by_id IS NOT NULL AND retired_at IS NOT NULL " \
      "AND ((activated_by_id IS NULL AND activated_at IS NULL) OR (activated_by_id IS NOT NULL AND activated_at IS NOT NULL))))",
      name: "marketing_capacity_policies_lifecycle_check"
    add_check_constraint :marketing_placement_capacity_policies,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND request_digest ~ '^[0-9a-f]{64}$'",
      name: "marketing_capacity_policies_digest_check"
  end
end
