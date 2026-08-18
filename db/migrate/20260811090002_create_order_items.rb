# frozen_string_literal: true

class CreateOrderItems < ActiveRecord::Migration[8.1]
  def change
    create_table :orders_order_items, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :order_id, null: false
      t.uuid :event_product_id, null: false
      t.uuid :registration_id
      # Reserved for the later Marketplace handoff; no placeholder table or FK
      # is created in the Orders phase.
      t.uuid :resale_listing_id
      t.string :name_snapshot, null: false
      t.string :type_snapshot, null: false
      t.integer :quantity, null: false
      t.integer :admissions_per_unit_snapshot, limit: 2
      t.string :base_currency, limit: 3, null: false
      t.bigint :base_unit_amount_minor, null: false
      t.string :charge_currency, limit: 3, null: false
      t.bigint :charge_unit_amount_minor, null: false
      t.decimal :exchange_rate, precision: 24, scale: 12
      t.bigint :discount_minor, null: false, default: 0
      t.bigint :total_minor, null: false
      t.string :fulfillment_status, null: false, default: "pending"

      t.timestamps
    end

    add_check_constraint :orders_order_items,
      "type_snapshot IN ('ticket','parking','merchandise','food','donation','digital_addon','other')",
      name: "orders_order_items_type_check"
    add_check_constraint :orders_order_items,
      "quantity > 0",
      name: "order_item_quantity_positive"
    add_check_constraint :orders_order_items,
      "((type_snapshot = 'ticket' AND admissions_per_unit_snapshot > 0) OR " \
      "(type_snapshot <> 'ticket' AND admissions_per_unit_snapshot IS NULL))",
      name: "orders_order_items_admissions_check"
    add_check_constraint :orders_order_items,
      "base_currency ~ '^[A-Z]{3}$' AND charge_currency ~ '^[A-Z]{3}$'",
      name: "orders_order_items_currency_check"
    add_check_constraint :orders_order_items,
      "base_unit_amount_minor >= 0 AND charge_unit_amount_minor >= 0 AND " \
      "discount_minor >= 0 AND total_minor >= 0",
      name: "orders_order_items_amounts_check"
    add_check_constraint :orders_order_items,
      "base_currency = charge_currency OR (exchange_rate IS NOT NULL AND exchange_rate > 0)",
      name: "orders_order_items_exchange_check"
    add_check_constraint :orders_order_items,
      "fulfillment_status IN ('pending','fulfilled','cancelled','refunded')",
      name: "orders_order_items_fulfillment_check"

    add_index :orders_order_items, :order_id, name: "idx_order_items_on_order"
    add_index :orders_order_items, :event_product_id, name: "idx_order_items_on_event_product"
    add_index :orders_order_items, %i[order_id fulfillment_status],
              name: "idx_order_items_on_order_fulfillment"
    add_index :orders_order_items, %i[registration_id],
              unique: true,
              where: "registration_id IS NOT NULL",
              name: "idx_one_order_item_per_registration"
    add_index :orders_order_items, :resale_listing_id,
              unique: true,
              where: "resale_listing_id IS NOT NULL",
              name: "idx_one_order_item_per_resale_listing"
    add_index :orders_order_items, %i[id order_id],
              unique: true,
              name: "idx_order_items_on_id_and_order"

    add_foreign_key :orders_order_items, :orders_orders, column: :order_id, on_delete: :restrict
    add_foreign_key :orders_order_items, :catalog_event_products,
                    column: :event_product_id, on_delete: :restrict
    add_foreign_key :orders_order_items, :ticketing_registrations,
                    column: :registration_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION orders_order_item_event_scope()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            order_event_id uuid;
            product_event_id uuid;
            product_type text;
            registration_event_id uuid;
          BEGIN
            SELECT event_id INTO order_event_id
            FROM orders_orders
            WHERE id = NEW.order_id;

            SELECT event_id, type INTO product_event_id, product_type
            FROM catalog_event_products
            WHERE id = NEW.event_product_id;

            IF order_event_id IS DISTINCT FROM product_event_id OR
               product_type IS DISTINCT FROM NEW.type_snapshot THEN
              RAISE EXCEPTION 'orders_order_item_event_scope' USING ERRCODE = '23514';
            END IF;

            IF NEW.registration_id IS NOT NULL THEN
              SELECT event_id INTO registration_event_id
              FROM ticketing_registrations
              WHERE id = NEW.registration_id;

              IF order_event_id IS DISTINCT FROM registration_event_id THEN
                RAISE EXCEPTION 'orders_order_item_registration_event_scope'
                  USING ERRCODE = '23514';
              END IF;
            END IF;

            RETURN NEW;
          END;
          $$;

          CREATE OR REPLACE FUNCTION orders_order_item_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            old_order_status text;
            new_order_status text;
          BEGIN
            IF TG_OP <> 'INSERT' THEN
              SELECT status INTO old_order_status FROM orders_orders WHERE id = OLD.order_id;
            END IF;
            IF TG_OP <> 'DELETE' THEN
              SELECT status INTO new_order_status FROM orders_orders WHERE id = NEW.order_id;
            END IF;

            IF old_order_status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded') OR
               new_order_status IN ('pending_payment','paid','fulfilled','expired','cancelled','partially_refunded','refunded') THEN
              IF TG_OP IN ('INSERT', 'DELETE') THEN
                RAISE EXCEPTION 'orders_order_item_snapshot_immutable' USING ERRCODE = '40001';
              END IF;

              IF (OLD.order_id, OLD.event_product_id, OLD.registration_id,
                  OLD.resale_listing_id, OLD.name_snapshot, OLD.type_snapshot, OLD.quantity,
                  OLD.admissions_per_unit_snapshot, OLD.base_currency,
                  OLD.base_unit_amount_minor, OLD.charge_currency,
                  OLD.charge_unit_amount_minor, OLD.exchange_rate, OLD.discount_minor,
                  OLD.total_minor)
                 IS DISTINCT FROM
                 (NEW.order_id, NEW.event_product_id, NEW.registration_id,
                  NEW.resale_listing_id, NEW.name_snapshot, NEW.type_snapshot, NEW.quantity,
                  NEW.admissions_per_unit_snapshot, NEW.base_currency,
                  NEW.base_unit_amount_minor, NEW.charge_currency,
                  NEW.charge_unit_amount_minor, NEW.exchange_rate, NEW.discount_minor,
                  NEW.total_minor) THEN
                RAISE EXCEPTION 'orders_order_item_snapshot_immutable' USING ERRCODE = '40001';
              END IF;
            END IF;

            IF TG_OP = 'DELETE' THEN
              RETURN OLD;
            END IF;
            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_orders_order_item_event_scope ON orders_order_items;
          CREATE TRIGGER trg_orders_order_item_event_scope
            BEFORE INSERT OR UPDATE ON orders_order_items
            FOR EACH ROW EXECUTE FUNCTION orders_order_item_event_scope();

          DROP TRIGGER IF EXISTS trg_orders_order_item_immutable ON orders_order_items;
          CREATE TRIGGER trg_orders_order_item_immutable
            BEFORE INSERT OR UPDATE OR DELETE ON orders_order_items
            FOR EACH ROW EXECUTE FUNCTION orders_order_item_immutable();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_orders_order_item_immutable ON orders_order_items;"
        execute "DROP TRIGGER IF EXISTS trg_orders_order_item_event_scope ON orders_order_items;"
        execute "DROP FUNCTION IF EXISTS orders_order_item_immutable();"
        execute "DROP FUNCTION IF EXISTS orders_order_item_event_scope();"
      end
    end
  end
end
