# frozen_string_literal: true

class CreateCommercialSubsidyReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_subsidy_reservations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :subsidy_budget_id, null: false
      t.uuid :order_id, null: false
      t.string :idempotency_key_digest, null: false, limit: 64
      t.string :request_fingerprint, null: false, limit: 64
      t.bigint :amount_minor, null: false
      t.string :currency, null: false, limit: 3
      t.string :status, null: false, default: "held"
      t.timestamptz :expires_at
      t.timestamptz :committed_at
      t.timestamptz :released_at

      t.timestamps
    end

    add_index :commercial_subsidy_reservations, :subsidy_budget_id,
              name: "idx_subsidy_reservations_on_budget"
    add_index :commercial_subsidy_reservations, :order_id,
              name: "idx_subsidy_reservations_on_order"
    add_index :commercial_subsidy_reservations, :idempotency_key_digest,
              unique: true,
              name: "idx_subsidy_reservations_on_idempotency"
    add_index :commercial_subsidy_reservations, %i[subsidy_budget_id order_id],
              unique: true,
              where: "status IN ('held','processing')",
              name: "idx_one_active_subsidy_reservation_per_order_budget"
    add_index :commercial_subsidy_reservations, %i[status expires_at],
              name: "idx_subsidy_reservations_on_status_and_expiry"

    add_check_constraint :commercial_subsidy_reservations,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$' AND request_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "commercial_subsidy_reservations_request_evidence_check"
    add_check_constraint :commercial_subsidy_reservations,
      "amount_minor > 0",
      name: "commercial_subsidy_reservations_amount_check"
    add_check_constraint :commercial_subsidy_reservations,
      "currency ~ '^[A-Z]{3}$'",
      name: "commercial_subsidy_reservations_currency_check"
    add_check_constraint :commercial_subsidy_reservations,
      "status IN ('held','processing','committed','released')",
      name: "commercial_subsidy_reservations_status_check"
    add_check_constraint :commercial_subsidy_reservations,
      "((status IN ('held','processing') AND expires_at IS NOT NULL AND committed_at IS NULL AND released_at IS NULL) OR " \
      "(status = 'committed' AND committed_at IS NOT NULL AND released_at IS NULL) OR " \
      "(status = 'released' AND released_at IS NOT NULL AND committed_at IS NULL))",
      name: "commercial_subsidy_reservations_state_check"

    add_foreign_key :commercial_subsidy_reservations,
      :commercial_subsidy_budgets,
      column: :subsidy_budget_id,
      on_delete: :restrict
    add_foreign_key :commercial_subsidy_reservations,
      :orders_orders,
      column: :order_id,
      on_delete: :restrict

    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION commercial_subsidy_reservation_immutable()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            IF TG_OP = 'DELETE' THEN
              IF OLD.status IN ('committed', 'released') THEN
                RAISE EXCEPTION 'commercial_subsidy_reservation_immutable' USING ERRCODE = '40001';
              END IF;

              RETURN OLD;
            END IF;

            IF (OLD.subsidy_budget_id, OLD.order_id, OLD.idempotency_key_digest,
                OLD.request_fingerprint, OLD.amount_minor, OLD.currency)
               IS DISTINCT FROM
               (NEW.subsidy_budget_id, NEW.order_id, NEW.idempotency_key_digest,
                NEW.request_fingerprint, NEW.amount_minor, NEW.currency) THEN
              RAISE EXCEPTION 'commercial_subsidy_reservation_immutable' USING ERRCODE = '40001';
            END IF;

            IF OLD.status IN ('committed', 'released') AND
               (OLD.status, OLD.committed_at, OLD.released_at) IS DISTINCT FROM
               (NEW.status, NEW.committed_at, NEW.released_at) THEN
              RAISE EXCEPTION 'commercial_subsidy_reservation_immutable' USING ERRCODE = '40001';
            END IF;

            RETURN NEW;
          END;
          $$;

          DROP TRIGGER IF EXISTS trg_commercial_subsidy_reservation_immutable
            ON commercial_subsidy_reservations;
          CREATE TRIGGER trg_commercial_subsidy_reservation_immutable
            BEFORE UPDATE OR DELETE ON commercial_subsidy_reservations
            FOR EACH ROW EXECUTE FUNCTION commercial_subsidy_reservation_immutable();
        SQL
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS trg_commercial_subsidy_reservation_immutable
            ON commercial_subsidy_reservations;
          DROP FUNCTION IF EXISTS commercial_subsidy_reservation_immutable();
        SQL
      end
    end
  end
end
