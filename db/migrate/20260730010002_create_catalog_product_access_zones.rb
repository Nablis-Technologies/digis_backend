# frozen_string_literal: true

class CreateCatalogProductAccessZones < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_product_access_zones, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :product_access_id, null: false
      t.uuid :access_zone_id, null: false

      t.timestamps
    end

    add_foreign_key :catalog_product_access_zones, :catalog_product_accesses,
                    column: :product_access_id
    add_foreign_key :catalog_product_access_zones, :events_access_zones,
                    column: :access_zone_id

    add_index :catalog_product_access_zones,
              %i[product_access_id access_zone_id],
              unique: true,
              name: "idx_access_zones_on_product_and_zone"
    add_index :catalog_product_access_zones, :access_zone_id
  end
end
