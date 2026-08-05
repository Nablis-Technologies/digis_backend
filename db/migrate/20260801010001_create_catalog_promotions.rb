# frozen_string_literal: true

class CreateCatalogPromotions < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_promotions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :supersedes_promotion_id
      t.integer :version, null: false, default: 1
      t.string :name, null: false
      t.string :type, null: false
      t.integer :percentage_basis_points
      t.bigint :fixed_amount_minor
      t.string :currency, limit: 3, null: false
      t.bigint :minimum_subtotal_minor
      t.bigint :maximum_discount_minor
      t.integer :redemption_limit
      t.integer :per_user_limit, null: false, default: 1
      t.timestamptz :starts_at
      t.timestamptz :ends_at
      t.string :status, null: false, default: "draft"
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_foreign_key :catalog_promotions, :events_events, column: :event_id
    add_foreign_key :catalog_promotions, :catalog_promotions,
                    column: :supersedes_promotion_id

    add_check_constraint :catalog_promotions,
      "type IN ('percentage', 'fixed')",
      name: "catalog_promotions_type_check"
    add_check_constraint :catalog_promotions,
      "status IN ('draft', 'active', 'disabled')",
      name: "catalog_promotions_status_check"
    add_check_constraint :catalog_promotions,
      "((type = 'percentage' AND percentage_basis_points IS NOT NULL AND fixed_amount_minor IS NULL) OR " \
      "(type = 'fixed' AND fixed_amount_minor IS NOT NULL AND percentage_basis_points IS NULL))",
      name: "catalog_promotions_calculation_check"
    add_check_constraint :catalog_promotions,
      "percentage_basis_points BETWEEN 1 AND 10000 OR percentage_basis_points IS NULL",
      name: "catalog_promotions_percentage_check"
    add_check_constraint :catalog_promotions,
      "fixed_amount_minor >= 0 OR fixed_amount_minor IS NULL",
      name: "catalog_promotions_fixed_amount_check"
    add_check_constraint :catalog_promotions,
      "minimum_subtotal_minor >= 0 OR minimum_subtotal_minor IS NULL",
      name: "catalog_promotions_minimum_subtotal_check"
    add_check_constraint :catalog_promotions,
      "maximum_discount_minor > 0 OR maximum_discount_minor IS NULL",
      name: "catalog_promotions_maximum_discount_check"
    add_check_constraint :catalog_promotions,
      "redemption_limit > 0 OR redemption_limit IS NULL",
      name: "catalog_promotions_redemption_limit_check"
    add_check_constraint :catalog_promotions,
      "per_user_limit > 0",
      name: "catalog_promotions_per_user_limit_check"
    add_check_constraint :catalog_promotions,
      "ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at",
      name: "catalog_promotions_window_check"

    add_index :catalog_promotions, :event_id
    add_index :catalog_promotions, :supersedes_promotion_id
    add_index :catalog_promotions, %i[event_id version]
    add_index :catalog_promotions, %i[event_id status]
  end
end
