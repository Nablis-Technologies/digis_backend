# frozen_string_literal: true

class CreateTicketingAdmissionUseReversals < ActiveRecord::Migration[8.1]
  def up
    create_table :ticketing_admission_use_reversals, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :admission_use_id, null: false
      t.uuid :checkin_log_id, null: false
      t.uuid :reversal_group_id, null: false
      t.uuid :reversed_by_id, null: false
      t.string :reason_code, null: false
      t.text :note
      t.bigint :reversal_version, null: false
      t.timestamptz :reversed_at, null: false

      t.timestamps
    end

    add_check_constraint :ticketing_admission_use_reversals,
      "btrim(reason_code) <> ''",
      name: "ticketing_admission_use_reversals_reason_check"
    add_check_constraint :ticketing_admission_use_reversals,
      "reversal_version > 0",
      name: "ticketing_admission_use_reversals_version_check"

    add_index :ticketing_admission_use_reversals, :admission_use_id, unique: true
    add_index :ticketing_admission_use_reversals, :reversal_group_id
    add_index :ticketing_admission_use_reversals, %i[event_id reversal_version]

    add_foreign_key :ticketing_admission_use_reversals, :events_events,
                    column: :event_id
    add_foreign_key :ticketing_admission_use_reversals,
                    :ticketing_admission_uses,
                    column: :admission_use_id
    add_foreign_key :ticketing_admission_use_reversals,
                    :ticketing_checkin_logs,
                    column: :checkin_log_id
    add_foreign_key :ticketing_admission_use_reversals, :core_users,
                    column: :reversed_by_id

    execute <<~SQL
      CREATE FUNCTION ticketing_admission_use_reversal_integrity() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        checkin_result text;
        checkin_event_id uuid;
        checkin_ticket_id uuid;
        checkin_use_count bigint;
        group_reversal_count bigint;
      BEGIN
        SELECT result, ticket_id INTO checkin_result, checkin_ticket_id
        FROM ticketing_checkin_logs WHERE id = NEW.checkin_log_id;

        SELECT event_id INTO checkin_event_id
        FROM ticketing_tickets WHERE id = checkin_ticket_id;

        IF checkin_result IS DISTINCT FROM 'success' OR
           checkin_event_id IS DISTINCT FROM NEW.event_id THEN
          RAISE EXCEPTION 'ticketing_admission_use_reversal_checkin_scope'
            USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
          SELECT 1
          FROM ticketing_admission_use_reversals existing
          WHERE existing.reversal_group_id = NEW.reversal_group_id
            AND (existing.event_id IS DISTINCT FROM NEW.event_id OR
                 existing.checkin_log_id IS DISTINCT FROM NEW.checkin_log_id)
        ) THEN
          RAISE EXCEPTION 'ticketing_admission_use_reversal_group_scope'
            USING ERRCODE = '23514';
        END IF;

        SELECT count(*) INTO checkin_use_count
        FROM ticketing_admission_uses
        WHERE checkin_log_id = NEW.checkin_log_id;

        SELECT count(*) INTO group_reversal_count
        FROM ticketing_admission_use_reversals
        WHERE reversal_group_id = NEW.reversal_group_id;

        IF checkin_use_count <> group_reversal_count OR EXISTS (
          SELECT 1
          FROM ticketing_admission_uses admission_use
          WHERE admission_use.checkin_log_id = NEW.checkin_log_id
            AND NOT EXISTS (
              SELECT 1
              FROM ticketing_admission_use_reversals reversal
              WHERE reversal.admission_use_id = admission_use.id
                AND reversal.reversal_group_id = NEW.reversal_group_id
            )
        ) THEN
          RAISE EXCEPTION 'ticketing_admission_use_reversal_incomplete_group'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE CONSTRAINT TRIGGER trg_ticketing_admission_use_reversal_integrity
      AFTER INSERT OR UPDATE ON ticketing_admission_use_reversals
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION ticketing_admission_use_reversal_integrity();

      CREATE FUNCTION ticketing_admission_use_reversal_append_only() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'ticketing_admission_use_reversals_append_only' USING ERRCODE = '40001';
      END;
      $$;

      CREATE TRIGGER trg_ticketing_admission_use_reversal_append_only
      BEFORE UPDATE OR DELETE ON ticketing_admission_use_reversals
      FOR EACH ROW EXECUTE FUNCTION ticketing_admission_use_reversal_append_only();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_ticketing_admission_use_reversal_append_only
        ON ticketing_admission_use_reversals;
      DROP TRIGGER IF EXISTS trg_ticketing_admission_use_reversal_integrity
        ON ticketing_admission_use_reversals;
      DROP FUNCTION IF EXISTS ticketing_admission_use_reversal_append_only();
      DROP FUNCTION IF EXISTS ticketing_admission_use_reversal_integrity();
    SQL
    drop_table :ticketing_admission_use_reversals
  end
end
