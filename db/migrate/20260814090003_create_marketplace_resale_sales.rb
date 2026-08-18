# frozen_string_literal: true

class CreateMarketplaceResaleSales < ActiveRecord::Migration[8.1]
  def change
    create_table :marketplace_resale_sales, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :resale_listing_id, null: false
      t.uuid :event_id, null: false
      t.uuid :ticket_id, null: false
      t.uuid :seller_user_id, null: false
      t.uuid :buyer_user_id, null: false
      t.uuid :buyer_registration_id, null: false
      t.uuid :buyer_order_id, null: false
      t.uuid :buyer_order_item_id, null: false
      t.uuid :accepted_payment_id, null: false
      t.uuid :seller_acquisition_order_item_id, null: false
      t.integer :resale_number, limit: 2, null: false
      t.bigint :gross_amount_minor, null: false
      t.string :currency, limit: 3, null: false
      t.bigint :marketplace_fee_minor, null: false
      t.bigint :seller_proceeds_minor, null: false
      t.uuid :commercial_fee_component_id, null: false
      t.uuid :commercial_fee_schedule_version_id, null: false
      t.string :fee_calculation_type, null: false
      t.string :fee_basis_type, null: false
      t.bigint :fee_fixed_amount_minor, null: false
      t.integer :fee_rate_bps, null: false
      t.bigint :fee_minimum_minor
      t.bigint :fee_maximum_minor
      t.string :status, null: false, default: "completed"
      t.timestamptz :completed_at, null: false
      t.string :idempotency_key, null: false

      t.timestamps
    end

    add_index :marketplace_resale_sales, :resale_listing_id, unique: true,
              name: "idx_one_resale_sale_per_listing"
    add_index :marketplace_resale_sales, %i[ticket_id resale_number], unique: true,
              name: "idx_one_resale_sale_per_ticket_sequence"
    add_index :marketplace_resale_sales, :buyer_registration_id, unique: true,
              name: "idx_one_resale_sale_per_buyer_registration"
    add_index :marketplace_resale_sales, :buyer_order_id, unique: true,
              name: "idx_one_resale_sale_per_buyer_order"
    add_index :marketplace_resale_sales, :buyer_order_item_id, unique: true,
              name: "idx_one_resale_sale_per_buyer_order_item"
    add_index :marketplace_resale_sales, :accepted_payment_id, unique: true,
              name: "idx_one_resale_sale_per_accepted_payment"
    add_index :marketplace_resale_sales, :idempotency_key, unique: true,
              name: "idx_marketplace_resale_sales_on_idempotency_key"
    add_index :marketplace_resale_sales, %i[event_id status completed_at],
              name: "idx_marketplace_resale_sales_on_event_status_completed"

    add_check_constraint :marketplace_resale_sales,
      "resale_number > 0",
      name: "marketplace_resale_sales_resale_number_check"
    add_check_constraint :marketplace_resale_sales,
      "gross_amount_minor > 0 AND marketplace_fee_minor >= 0 AND seller_proceeds_minor >= 0 AND " \
      "(fee_fixed_amount_minor IS NULL OR fee_fixed_amount_minor >= 0) AND " \
      "(fee_minimum_minor IS NULL OR fee_minimum_minor >= 0) AND " \
      "(fee_maximum_minor IS NULL OR fee_maximum_minor >= 0)",
      name: "marketplace_resale_sales_amounts_check"
    add_check_constraint :marketplace_resale_sales,
      "currency ~ '^[A-Z]{3}$' AND (fee_rate_bps IS NULL OR fee_rate_bps BETWEEN 0 AND 10000)",
      name: "marketplace_resale_sales_currency_rate_check"
    add_check_constraint :marketplace_resale_sales,
      "gross_amount_minor = marketplace_fee_minor + seller_proceeds_minor AND " \
      "marketplace_fee_minor <= gross_amount_minor",
      name: "marketplace_resale_sales_gross_reconciles_check"
    add_check_constraint :marketplace_resale_sales,
      "status IN ('completed','partially_cancelled','cancelled')",
      name: "marketplace_resale_sales_status_check"

    add_foreign_key :marketplace_resale_sales, :marketplace_resale_listings,
                    column: :resale_listing_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_sales, :events_events,
                    column: :event_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_sales, :ticketing_tickets,
                    column: :ticket_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_sales, :core_users,
                    column: :seller_user_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_sales, :core_users,
                    column: :buyer_user_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_sales, :ticketing_registrations,
                    column: :buyer_registration_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_sales, :orders_orders,
                    column: :buyer_order_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_sales, :orders_order_items,
                    column: :buyer_order_item_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_sales, :orders_payments,
                    column: :accepted_payment_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_sales, :orders_order_items,
                    column: :seller_acquisition_order_item_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_sales, :commercial_fee_components,
                    column: :commercial_fee_component_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_sales, :commercial_fee_schedule_versions,
                    column: :commercial_fee_schedule_version_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION marketplace_resale_sale_integrity()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            listing_event_id uuid;
            listing_ticket_id uuid;
            listing_seller_id uuid;
            listing_order_id uuid;
            listing_status text;
            listing_resale_count smallint;
            ticket_event_id uuid;
            ticket_owner_id uuid;
            ticket_current_order_item_id uuid;
            ticket_resale_count smallint;
            order_event_id uuid;
            order_buyer_id uuid;
            order_total bigint;
            order_currency text;
            order_settlement_total bigint;
            order_settlement_currency text;
            order_status text;
            order_sales_channel text;
            registration_event_id uuid;
            registration_user_id uuid;
            buyer_item_order_id uuid;
            buyer_item_registration_id uuid;
            buyer_item_listing_id uuid;
            payment_order_id uuid;
            payment_status text;
            payment_accepted_at timestamptz;
            payment_amount bigint;
            payment_currency text;
            event_currency text;
            component_version_id uuid;
            component_type text;
            component_sale_context text;
          BEGIN
            SELECT event_id, ticket_id, seller_user_id, reserved_order_id, status, resale_count_before
              INTO listing_event_id, listing_ticket_id, listing_seller_id,
                   listing_order_id, listing_status, listing_resale_count
            FROM marketplace_resale_listings
            WHERE id = NEW.resale_listing_id;

            SELECT event_id, owner_user_id, current_acquisition_order_item_id, completed_resale_count
              INTO ticket_event_id, ticket_owner_id, ticket_current_order_item_id, ticket_resale_count
            FROM ticketing_tickets
            WHERE id = NEW.ticket_id;

            SELECT event_id, buyer_user_id, total_minor, charge_currency,
                   settlement_total_minor, settlement_currency, status, sales_channel
              INTO order_event_id, order_buyer_id, order_total, order_currency,
                   order_settlement_total, order_settlement_currency, order_status, order_sales_channel
            FROM orders_orders
            WHERE id = NEW.buyer_order_id;

            SELECT event_id, user_id
              INTO registration_event_id, registration_user_id
            FROM ticketing_registrations
            WHERE id = NEW.buyer_registration_id;

            SELECT order_id, registration_id, resale_listing_id
              INTO buyer_item_order_id, buyer_item_registration_id, buyer_item_listing_id
            FROM orders_order_items
            WHERE id = NEW.buyer_order_item_id;

            SELECT order_id, status, accepted_at, amount_minor, currency
              INTO payment_order_id, payment_status, payment_accepted_at, payment_amount, payment_currency
            FROM orders_payments
            WHERE id = NEW.accepted_payment_id;

            SELECT currency INTO event_currency FROM events_events WHERE id = NEW.event_id;

            SELECT fee_schedule_version_id, commercial_fee_components.component_type,
                   commercial_fee_components.sale_context
              INTO component_version_id, component_type, component_sale_context
            FROM commercial_fee_components
            WHERE id = NEW.commercial_fee_component_id;

            IF listing_status IS DISTINCT FROM 'reserved' OR
               listing_event_id IS DISTINCT FROM NEW.event_id OR
               listing_ticket_id IS DISTINCT FROM NEW.ticket_id OR
               listing_seller_id IS DISTINCT FROM NEW.seller_user_id OR
               listing_order_id IS DISTINCT FROM NEW.buyer_order_id OR
               ticket_event_id IS DISTINCT FROM NEW.event_id OR
               ticket_owner_id IS DISTINCT FROM NEW.seller_user_id OR
               ticket_current_order_item_id IS DISTINCT FROM NEW.seller_acquisition_order_item_id OR
               ticket_resale_count IS DISTINCT FROM listing_resale_count OR
               NEW.resale_number IS DISTINCT FROM ticket_resale_count + 1 OR
               order_event_id IS DISTINCT FROM NEW.event_id OR
               order_buyer_id IS DISTINCT FROM NEW.buyer_user_id OR
               order_settlement_total IS DISTINCT FROM NEW.gross_amount_minor OR
               order_settlement_currency IS DISTINCT FROM NEW.currency OR
               order_status NOT IN ('paid','fulfilled','partially_refunded','refunded') OR
               order_sales_channel IS DISTINCT FROM 'resale' OR
               registration_event_id IS DISTINCT FROM NEW.event_id OR
               registration_user_id IS DISTINCT FROM NEW.buyer_user_id OR
               buyer_item_order_id IS DISTINCT FROM NEW.buyer_order_id OR
               buyer_item_registration_id IS DISTINCT FROM NEW.buyer_registration_id OR
               buyer_item_listing_id IS DISTINCT FROM NEW.resale_listing_id OR
               payment_order_id IS DISTINCT FROM NEW.buyer_order_id OR
               payment_status IS DISTINCT FROM 'succeeded' OR
               payment_accepted_at IS NULL OR
               payment_amount IS DISTINCT FROM order_total OR
               payment_currency IS DISTINCT FROM order_currency OR
               event_currency IS DISTINCT FROM NEW.currency OR
               component_version_id IS DISTINCT FROM NEW.commercial_fee_schedule_version_id OR
               component_type IS DISTINCT FROM 'resale_platform_fee' OR
               component_sale_context IS DISTINCT FROM 'resale' THEN
              RAISE EXCEPTION 'marketplace_resale_sale_scope_mismatch' USING ERRCODE = '23514';
            END IF;

            RETURN NEW;
          END;
          $$;

          CREATE OR REPLACE FUNCTION marketplace_resale_sale_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            IF TG_OP = 'DELETE' OR
               (OLD.resale_listing_id, OLD.event_id, OLD.ticket_id, OLD.seller_user_id,
                OLD.buyer_user_id, OLD.buyer_registration_id, OLD.buyer_order_id,
                OLD.buyer_order_item_id, OLD.accepted_payment_id, OLD.seller_acquisition_order_item_id,
                OLD.resale_number, OLD.gross_amount_minor, OLD.currency, OLD.marketplace_fee_minor,
                OLD.seller_proceeds_minor, OLD.commercial_fee_component_id,
                OLD.commercial_fee_schedule_version_id, OLD.fee_calculation_type, OLD.fee_basis_type,
                OLD.fee_fixed_amount_minor, OLD.fee_rate_bps, OLD.fee_minimum_minor, OLD.fee_maximum_minor)
                IS DISTINCT FROM
               (NEW.resale_listing_id, NEW.event_id, NEW.ticket_id, NEW.seller_user_id,
                NEW.buyer_user_id, NEW.buyer_registration_id, NEW.buyer_order_id,
                NEW.buyer_order_item_id, NEW.accepted_payment_id, NEW.seller_acquisition_order_item_id,
                NEW.resale_number, NEW.gross_amount_minor, NEW.currency, NEW.marketplace_fee_minor,
                NEW.seller_proceeds_minor, NEW.commercial_fee_component_id,
                NEW.commercial_fee_schedule_version_id, NEW.fee_calculation_type, NEW.fee_basis_type,
                NEW.fee_fixed_amount_minor, NEW.fee_rate_bps, NEW.fee_minimum_minor, NEW.fee_maximum_minor) THEN
              RAISE EXCEPTION 'marketplace_resale_sale_immutable' USING ERRCODE = '40001';
            END IF;

            RETURN COALESCE(NEW, OLD);
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_marketplace_resale_sale_integrity ON marketplace_resale_sales;
          CREATE TRIGGER trg_marketplace_resale_sale_integrity
            BEFORE INSERT ON marketplace_resale_sales
            FOR EACH ROW EXECUTE FUNCTION marketplace_resale_sale_integrity();
          DROP TRIGGER IF EXISTS trg_marketplace_resale_sale_immutable ON marketplace_resale_sales;
          CREATE TRIGGER trg_marketplace_resale_sale_immutable
            BEFORE UPDATE OR DELETE ON marketplace_resale_sales
            FOR EACH ROW EXECUTE FUNCTION marketplace_resale_sale_immutable();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_marketplace_resale_sale_immutable ON marketplace_resale_sales;"
        execute "DROP TRIGGER IF EXISTS trg_marketplace_resale_sale_integrity ON marketplace_resale_sales;"
        execute "DROP FUNCTION IF EXISTS marketplace_resale_sale_immutable();"
        execute "DROP FUNCTION IF EXISTS marketplace_resale_sale_integrity();"
      end
    end
  end
end
