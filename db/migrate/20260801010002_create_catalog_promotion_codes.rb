# frozen_string_literal: true

class CreateCatalogPromotionCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_promotion_codes, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :promotion_id, null: false
      t.string :code_digest, limit: 64, null: false
      t.text :code_ciphertext, null: false
      t.string :label
      t.integer :redemption_limit
      t.timestamptz :starts_at
      t.timestamptz :ends_at
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_foreign_key :catalog_promotion_codes, :catalog_promotions,
                    column: :promotion_id

    add_check_constraint :catalog_promotion_codes,
      "redemption_limit > 0 OR redemption_limit IS NULL",
      name: "catalog_promotion_codes_redemption_limit_check"
    add_check_constraint :catalog_promotion_codes,
      "ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at",
      name: "catalog_promotion_codes_window_check"

    add_index :catalog_promotion_codes, :code_digest, unique: true
    add_index :catalog_promotion_codes, :promotion_id
    add_index :catalog_promotion_codes, %i[promotion_id active]
  end
end
