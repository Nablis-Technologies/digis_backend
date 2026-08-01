# frozen_string_literal: true

class CreateCatalogPromotionProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_promotion_products, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :promotion_id, null: false
      t.uuid :event_product_id, null: false

      t.timestamps
    end

    add_foreign_key :catalog_promotion_products, :catalog_promotions,
                    column: :promotion_id
    add_foreign_key :catalog_promotion_products, :catalog_event_products,
                    column: :event_product_id

    add_index :catalog_promotion_products,
              %i[promotion_id event_product_id],
              unique: true,
              name: "idx_promotion_products_on_promotion_and_product"
    add_index :catalog_promotion_products, :event_product_id
  end
end
