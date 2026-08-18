# frozen_string_literal: true

class CreateTicketingAdmissionUses < ActiveRecord::Migration[8.1]
  def up
    create_table :ticketing_admission_uses, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :admission_slot_id, null: false
      t.uuid :product_access_id, null: false
      t.uuid :credential_id, null: false
      t.uuid :checkin_log_id, null: false
      t.integer :usage_number, null: false
      t.timestamptz :used_at, null: false

      t.timestamps
    end

    add_check_constraint :ticketing_admission_uses,
      "usage_number > 0",
      name: "ticketing_admission_uses_usage_number_check"
    add_index :ticketing_admission_uses,
              %i[admission_slot_id product_access_id usage_number],
              unique: true
    add_index :ticketing_admission_uses, %i[checkin_log_id admission_slot_id]
    add_index :ticketing_admission_uses, %i[product_access_id used_at]

    add_foreign_key :ticketing_admission_uses, :ticketing_admission_slots,
                    column: :admission_slot_id
    add_foreign_key :ticketing_admission_uses, :catalog_product_accesses,
                    column: :product_access_id
    add_foreign_key :ticketing_admission_uses, :ticketing_credentials,
                    column: :credential_id
    add_foreign_key :ticketing_admission_uses, :ticketing_checkin_logs,
                    column: :checkin_log_id

    execute <<~SQL
      CREATE FUNCTION ticketing_admission_use_integrity() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        slot_ticket_id uuid;
        credential_ticket_id uuid;
        checkin_ticket_id uuid;
        checkin_product_access_id uuid;
        checkin_event_date_id uuid;
        product_access_event_date_id uuid;
        checkin_result text;
      BEGIN
        SELECT ticket_id INTO slot_ticket_id
        FROM ticketing_admission_slots WHERE id = NEW.admission_slot_id;

        SELECT ticket_id INTO credential_ticket_id
        FROM ticketing_credentials WHERE id = NEW.credential_id;

        SELECT ticket_id, product_access_id, event_date_id, result
          INTO checkin_ticket_id, checkin_product_access_id, checkin_event_date_id, checkin_result
        FROM ticketing_checkin_logs WHERE id = NEW.checkin_log_id;

        SELECT event_date_id INTO product_access_event_date_id
        FROM catalog_product_accesses WHERE id = NEW.product_access_id;

        IF checkin_result IS DISTINCT FROM 'success' OR
           slot_ticket_id IS DISTINCT FROM credential_ticket_id OR
           slot_ticket_id IS DISTINCT FROM checkin_ticket_id OR
           NEW.product_access_id IS DISTINCT FROM checkin_product_access_id OR
           checkin_event_date_id IS DISTINCT FROM product_access_event_date_id THEN
          RAISE EXCEPTION 'ticketing_admission_use_scope' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE CONSTRAINT TRIGGER trg_ticketing_admission_use_integrity
      AFTER INSERT OR UPDATE ON ticketing_admission_uses
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION ticketing_admission_use_integrity();

      CREATE FUNCTION ticketing_admission_use_append_only() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'ticketing_admission_uses_append_only' USING ERRCODE = '40001';
      END;
      $$;

      CREATE TRIGGER trg_ticketing_admission_use_append_only
      BEFORE UPDATE OR DELETE ON ticketing_admission_uses
      FOR EACH ROW EXECUTE FUNCTION ticketing_admission_use_append_only();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_ticketing_admission_use_append_only ON ticketing_admission_uses;
      DROP TRIGGER IF EXISTS trg_ticketing_admission_use_integrity ON ticketing_admission_uses;
      DROP FUNCTION IF EXISTS ticketing_admission_use_append_only();
      DROP FUNCTION IF EXISTS ticketing_admission_use_integrity();
    SQL
    drop_table :ticketing_admission_uses
  end
end
