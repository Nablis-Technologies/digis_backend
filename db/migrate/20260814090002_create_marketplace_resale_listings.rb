# frozen_string_literal: true

class CreateMarketplaceResaleListings < ActiveRecord::Migration[8.1]
  def change
    create_table :marketplace_resale_listings, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :ticket_id, null: false
      t.uuid :ticket_type_id, null: false
      t.uuid :seller_user_id, null: false
      t.string :status, null: false, default: "draft"
      t.bigint :asking_amount_minor, null: false
      t.string :currency, limit: 3, null: false
      t.bigint :seller_acquisition_product_value_minor, null: false
      t.string :cap_type_snapshot, null: false
      t.bigint :fixed_cap_minor_snapshot
      t.integer :percentage_cap_bps_snapshot
      t.bigint :calculated_cap_minor, null: false
      t.integer :resale_count_before, limit: 2, null: false
      t.integer :max_completed_resales_snapshot, limit: 2, null: false
      t.timestamptz :resale_cutoff_at, null: false
      t.uuid :commercial_fee_component_id, null: false
      t.uuid :commercial_fee_schedule_version_id, null: false
      t.uuid :reserved_order_id
      t.timestamptz :reserved_at
      t.timestamptz :reservation_expires_at
      t.string :idempotency_key, null: false
      t.timestamptz :activated_at
      t.timestamptz :sold_at
      t.timestamptz :closed_at
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :marketplace_resale_listings, :ticket_id,
              unique: true,
              where: "status IN ('active','reserved')",
              name: "idx_one_open_resale_listing_per_ticket"
    add_index :marketplace_resale_listings, :reserved_order_id,
              unique: true,
              where: "reserved_order_id IS NOT NULL",
              name: "idx_one_resale_listing_per_reserved_order"
    add_index :marketplace_resale_listings, :idempotency_key,
              unique: true,
              name: "idx_marketplace_resale_listings_on_idempotency_key"
    add_index :marketplace_resale_listings, %i[event_id status created_at],
              name: "idx_marketplace_resale_listings_on_event_status_created"
    add_index :marketplace_resale_listings, %i[seller_user_id status created_at],
              name: "idx_marketplace_resale_listings_on_seller_status_created"

    add_check_constraint :marketplace_resale_listings,
      "status IN ('draft','active','reserved','sold','cancelled','expired')",
      name: "marketplace_resale_listings_status_check"
    add_check_constraint :marketplace_resale_listings,
      "asking_amount_minor > 0 AND seller_acquisition_product_value_minor > 0 AND " \
      "calculated_cap_minor > 0",
      name: "marketplace_resale_listings_positive_amounts_check"
    add_check_constraint :marketplace_resale_listings,
      "currency ~ '^[A-Z]{3}$'",
      name: "marketplace_resale_listings_currency_check"
    add_check_constraint :marketplace_resale_listings,
      "resale_count_before >= 0 AND max_completed_resales_snapshot > 0 AND " \
      "resale_count_before < max_completed_resales_snapshot AND lock_version >= 0",
      name: "marketplace_resale_listings_resale_count_check"
    add_check_constraint :marketplace_resale_listings,
      "((cap_type_snapshot = 'fixed' AND fixed_cap_minor_snapshot IS NOT NULL AND " \
      "percentage_cap_bps_snapshot IS NULL) OR " \
      "(cap_type_snapshot = 'percentage' AND fixed_cap_minor_snapshot IS NULL AND " \
      "percentage_cap_bps_snapshot BETWEEN 1 AND 10000))",
      name: "marketplace_resale_listings_cap_shape_check"
    add_check_constraint :marketplace_resale_listings,
      "cap_type_snapshot IN ('fixed','percentage')",
      name: "marketplace_resale_listings_cap_type_check"
    add_check_constraint :marketplace_resale_listings,
      "asking_amount_minor <= calculated_cap_minor",
      name: "marketplace_resale_listings_asking_cap_check"
    add_check_constraint :marketplace_resale_listings,
      "((status IN ('reserved','sold') AND reserved_order_id IS NOT NULL AND " \
      "reserved_at IS NOT NULL AND reservation_expires_at IS NOT NULL) OR " \
      "(status NOT IN ('reserved','sold') AND reserved_order_id IS NULL AND " \
      "reserved_at IS NULL AND reservation_expires_at IS NULL))",
      name: "marketplace_resale_listings_reservation_state_check"
    add_check_constraint :marketplace_resale_listings,
      "((status IN ('active','reserved','sold') AND activated_at IS NOT NULL) OR " \
      "(status NOT IN ('active','reserved','sold') AND activated_at IS NULL))",
      name: "marketplace_resale_listings_activation_state_check"
    add_check_constraint :marketplace_resale_listings,
      "((status = 'sold') = (sold_at IS NOT NULL)) AND " \
      "((status IN ('sold','cancelled','expired')) = (closed_at IS NOT NULL))",
      name: "marketplace_resale_listings_closure_state_check"

    add_foreign_key :marketplace_resale_listings, :events_events,
                    column: :event_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_listings, :ticketing_tickets,
                    column: :ticket_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_listings, :ticketing_ticket_types,
                    column: :ticket_type_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_listings, :core_users,
                    column: :seller_user_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_listings, :orders_orders,
                    column: :reserved_order_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_listings, :commercial_fee_components,
                    column: :commercial_fee_component_id, on_delete: :restrict
    add_foreign_key :marketplace_resale_listings, :commercial_fee_schedule_versions,
                    column: :commercial_fee_schedule_version_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION marketplace_resale_listing_scope()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            ticket_event_id uuid;
            ticket_product_id uuid;
            ticket_owner_id uuid;
            ticket_value bigint;
            ticket_currency text;
            product_event_id uuid;
            product_ticket_type_id uuid;
            event_currency text;
            ticket_resale_count smallint;
            component_version_id uuid;
            component_type text;
            component_sale_context text;
          BEGIN
            SELECT event_id, event_product_id, owner_user_id,
                   current_acquisition_product_value_minor, current_acquisition_currency,
                   completed_resale_count
              INTO ticket_event_id, ticket_product_id, ticket_owner_id,
                   ticket_value, ticket_currency, ticket_resale_count
            FROM ticketing_tickets
            WHERE id = NEW.ticket_id;

            SELECT catalog_event_products.event_id, ticketing_ticket_types.id
              INTO product_event_id, product_ticket_type_id
            FROM catalog_event_products
            JOIN ticketing_ticket_types ON ticketing_ticket_types.event_product_id = catalog_event_products.id
            WHERE catalog_event_products.id = ticket_product_id;

            SELECT currency INTO event_currency FROM events_events WHERE id = NEW.event_id;

            SELECT fee_schedule_version_id, commercial_fee_components.component_type,
                   commercial_fee_components.sale_context
              INTO component_version_id, component_type, component_sale_context
            FROM commercial_fee_components
            WHERE id = NEW.commercial_fee_component_id;

            IF NEW.event_id IS DISTINCT FROM ticket_event_id OR
               NEW.event_id IS DISTINCT FROM product_event_id OR
               NEW.ticket_type_id IS DISTINCT FROM product_ticket_type_id OR
               NEW.currency IS DISTINCT FROM event_currency OR
               NEW.seller_acquisition_product_value_minor IS DISTINCT FROM ticket_value OR
               NEW.currency IS DISTINCT FROM ticket_currency OR
               NEW.resale_count_before IS DISTINCT FROM ticket_resale_count OR
               component_version_id IS DISTINCT FROM NEW.commercial_fee_schedule_version_id OR
               component_type IS DISTINCT FROM 'resale_platform_fee' OR
               component_sale_context IS DISTINCT FROM 'resale' OR
               (NEW.status IN ('draft','active','reserved') AND NEW.seller_user_id IS DISTINCT FROM ticket_owner_id) THEN
              RAISE EXCEPTION 'marketplace_resale_listing_scope_mismatch' USING ERRCODE = '23514';
            END IF;

            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_marketplace_resale_listing_scope
            ON marketplace_resale_listings;
          CREATE TRIGGER trg_marketplace_resale_listing_scope
            BEFORE INSERT OR UPDATE ON marketplace_resale_listings
            FOR EACH ROW EXECUTE FUNCTION marketplace_resale_listing_scope();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_marketplace_resale_listing_scope ON marketplace_resale_listings;"
        execute "DROP FUNCTION IF EXISTS marketplace_resale_listing_scope();"
      end
    end
  end
end
