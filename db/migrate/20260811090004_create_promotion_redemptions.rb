# frozen_string_literal: true

class CreatePromotionRedemptions < ActiveRecord::Migration[8.1]
  def change
    create_table :orders_promotion_redemptions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :order_id, null: false
      t.uuid :promotion_id, null: false
      t.uuid :promotion_code_id
      t.uuid :user_id, null: false
      t.string :status, null: false, default: "reserved"
      t.bigint :discount_minor, null: false
      t.string :currency, limit: 3, null: false
      t.string :idempotency_key, null: false
      t.timestamptz :expires_at
      t.timestamptz :applied_at
      t.timestamptz :released_at

      t.timestamps
    end

    add_check_constraint :orders_promotion_redemptions,
      "status IN ('reserved','applied','released','expired')",
      name: "promotion_redemptions_status_check"
    add_check_constraint :orders_promotion_redemptions,
      "discount_minor > 0",
      name: "promotion_redemptions_discount_check"
    add_check_constraint :orders_promotion_redemptions,
      "currency ~ '^[A-Z]{3}$'",
      name: "promotion_redemptions_currency_check"
    add_check_constraint :orders_promotion_redemptions,
      "((status = 'reserved' AND expires_at IS NOT NULL AND applied_at IS NULL AND released_at IS NULL) OR " \
      "(status = 'applied' AND applied_at IS NOT NULL AND released_at IS NULL) OR " \
      "(status = 'released' AND released_at IS NOT NULL AND applied_at IS NULL) OR " \
      "(status = 'expired' AND expires_at IS NOT NULL AND released_at IS NOT NULL AND applied_at IS NULL))",
      name: "promotion_redemptions_state_check"

    add_index :orders_promotion_redemptions, :order_id,
              unique: true,
              name: "idx_one_promotion_redemption_per_order"
    add_index :orders_promotion_redemptions, %i[promotion_id user_id status],
              name: "idx_promotion_redemptions_on_promotion_user_status"
    add_index :orders_promotion_redemptions, %i[promotion_id status expires_at],
              name: "idx_promotion_redemptions_on_promotion_status_expiry"
    add_index :orders_promotion_redemptions, %i[promotion_code_id status expires_at],
              name: "idx_promotion_redemptions_on_code_status_expiry"
    add_index :orders_promotion_redemptions, :idempotency_key,
              unique: true,
              name: "idx_promotion_redemptions_on_idempotency"

    add_foreign_key :orders_promotion_redemptions, :orders_orders,
                    column: :order_id, on_delete: :restrict
    add_foreign_key :orders_promotion_redemptions, :catalog_promotions,
                    column: :promotion_id, on_delete: :restrict
    add_foreign_key :orders_promotion_redemptions, :catalog_promotion_codes,
                    column: :promotion_code_id, on_delete: :restrict
    add_foreign_key :orders_promotion_redemptions, :core_users,
                    column: :user_id, on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION orders_promotion_redemption_scope()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          DECLARE
            order_event_id uuid;
            order_buyer_id uuid;
            order_currency text;
            promotion_event_id uuid;
            code_promotion_id uuid;
          BEGIN
            SELECT event_id, buyer_user_id, charge_currency
              INTO order_event_id, order_buyer_id, order_currency
            FROM orders_orders
            WHERE id = NEW.order_id;
            SELECT event_id INTO promotion_event_id
            FROM catalog_promotions
            WHERE id = NEW.promotion_id;

            IF order_event_id IS DISTINCT FROM promotion_event_id OR
               order_buyer_id IS DISTINCT FROM NEW.user_id OR
               order_currency IS DISTINCT FROM NEW.currency THEN
              RAISE EXCEPTION 'orders_promotion_redemption_scope' USING ERRCODE = '23514';
            END IF;

            IF NEW.promotion_code_id IS NOT NULL THEN
              SELECT promotion_id INTO code_promotion_id
              FROM catalog_promotion_codes
              WHERE id = NEW.promotion_code_id;

              IF code_promotion_id IS DISTINCT FROM NEW.promotion_id THEN
                RAISE EXCEPTION 'orders_promotion_redemption_code_scope'
                  USING ERRCODE = '23514';
              END IF;
            END IF;
            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_orders_promotion_redemption_scope
            ON orders_promotion_redemptions;
          CREATE TRIGGER trg_orders_promotion_redemption_scope
            BEFORE INSERT OR UPDATE ON orders_promotion_redemptions
            FOR EACH ROW EXECUTE FUNCTION orders_promotion_redemption_scope();
        SQL
      end

      dir.down do
        execute "DROP TRIGGER IF EXISTS trg_orders_promotion_redemption_scope ON orders_promotion_redemptions;"
        execute "DROP FUNCTION IF EXISTS orders_promotion_redemption_scope();"
      end
    end
  end
end
