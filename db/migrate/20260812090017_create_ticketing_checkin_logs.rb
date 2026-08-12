# frozen_string_literal: true

class CreateTicketingCheckinLogs < ActiveRecord::Migration[8.1]
  RESULTS = %w[success duplicate invalid version_mismatch revoked wrong_date wrong_channel wrong_zone identity_mismatch].freeze
  LOOKUP_METHODS = %w[qr code phone name].freeze
  IDENTITY_RESULTS = %w[not_required matched mismatch].freeze

  def up
    create_table :ticketing_checkin_logs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :ticket_id, null: false
      t.uuid :credential_id, null: false
      t.integer :credential_version, null: false
      t.uuid :product_access_id, null: false
      t.uuid :event_date_id, null: false
      t.uuid :access_zone_id
      t.uuid :scanner_device_assignment_id
      t.uuid :scan_upload_id
      t.uuid :client_scan_id, null: false
      t.string :result, null: false
      t.string :lookup_via, null: false
      t.string :reason_code
      t.string :identity_check_result, null: false, default: "not_required"
      t.uuid :identity_checked_by_id
      t.uuid :overrides_checkin_log_id
      t.uuid :identity_override_by_id
      t.string :identity_override_reason
      t.timestamptz :identity_overridden_at
      t.timestamptz :scanned_at, null: false
      t.timestamptz :received_at, null: false

      t.timestamps
    end

    add_check_constraint :ticketing_checkin_logs,
      "credential_version > 0",
      name: "ticketing_checkin_logs_credential_version_check"
    add_check_constraint :ticketing_checkin_logs,
      "result IN (#{quoted_values(RESULTS)})",
      name: "ticketing_checkin_logs_result_check"
    add_check_constraint :ticketing_checkin_logs,
      "lookup_via IN (#{quoted_values(LOOKUP_METHODS)})",
      name: "ticketing_checkin_logs_lookup_via_check"
    add_check_constraint :ticketing_checkin_logs,
      "identity_check_result IN (#{quoted_values(IDENTITY_RESULTS)})",
      name: "ticketing_checkin_logs_identity_result_check"
    add_check_constraint :ticketing_checkin_logs,
      "lookup_via = 'qr' OR btrim(reason_code) <> ''",
      name: "ticketing_checkin_logs_manual_reason_check"
    add_check_constraint :ticketing_checkin_logs,
      "((identity_check_result = 'not_required' AND identity_checked_by_id IS NULL) OR " \
        "(identity_check_result IN ('matched','mismatch') AND identity_checked_by_id IS NOT NULL))",
      name: "ticketing_checkin_logs_identity_check_shape"
    add_check_constraint :ticketing_checkin_logs,
      "((identity_override_by_id IS NULL AND identity_override_reason IS NULL AND " \
        "identity_overridden_at IS NULL AND overrides_checkin_log_id IS NULL) OR " \
        "(identity_override_by_id IS NOT NULL AND identity_check_result = 'mismatch' AND " \
        "result = 'success' AND btrim(identity_override_reason) <> '' AND " \
        "identity_overridden_at IS NOT NULL AND overrides_checkin_log_id IS NOT NULL AND " \
        "scan_upload_id IS NULL))",
      name: "ticketing_checkin_logs_identity_override_shape"

    add_index :ticketing_checkin_logs, :client_scan_id, unique: true
    add_index :ticketing_checkin_logs, :overrides_checkin_log_id,
              unique: true,
              where: "overrides_checkin_log_id IS NOT NULL"
    add_index :ticketing_checkin_logs, %i[ticket_id event_date_id result]
    add_index :ticketing_checkin_logs, %i[credential_id received_at]
    add_index :ticketing_checkin_logs, %i[event_date_id received_at]

    add_foreign_key :ticketing_checkin_logs, :ticketing_tickets, column: :ticket_id
    add_foreign_key :ticketing_checkin_logs, :ticketing_credentials, column: :credential_id
    add_foreign_key :ticketing_checkin_logs, :catalog_product_accesses,
                    column: :product_access_id
    add_foreign_key :ticketing_checkin_logs, :events_event_dates,
                    column: :event_date_id
    add_foreign_key :ticketing_checkin_logs,
                    :events_access_zones,
                    column: :access_zone_id
    add_foreign_key :ticketing_checkin_logs,
                    :ticketing_scanner_device_assignments,
                    column: :scanner_device_assignment_id
    add_foreign_key :ticketing_checkin_logs, :ticketing_scan_uploads,
                    column: :scan_upload_id
    add_foreign_key :ticketing_checkin_logs, :core_users,
                    column: :identity_checked_by_id
    add_foreign_key :ticketing_checkin_logs, :ticketing_checkin_logs,
                    column: :overrides_checkin_log_id
    add_foreign_key :ticketing_checkin_logs, :core_users,
                    column: :identity_override_by_id

    execute <<~SQL
      CREATE FUNCTION ticketing_checkin_log_scope() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        ticket_event_id uuid;
        product_access_event_id uuid;
        product_access_event_date_id uuid;
        event_date_event_id uuid;
        credential_ticket_id uuid;
        assignment_event_id uuid;
        upload_assignment_id uuid;
        zone_event_id uuid;
        zone_event_date_id uuid;
        override_result text;
        override_ticket_id uuid;
      BEGIN
        SELECT event_id INTO ticket_event_id
        FROM ticketing_tickets WHERE id = NEW.ticket_id;

        SELECT product.event_id, access.event_date_id
          INTO product_access_event_id, product_access_event_date_id
        FROM catalog_product_accesses access
        JOIN catalog_event_products product
          ON product.id = access.event_product_id
        WHERE access.id = NEW.product_access_id;

        SELECT event_id INTO event_date_event_id
        FROM events_event_dates WHERE id = NEW.event_date_id;

        SELECT ticket_id INTO credential_ticket_id
        FROM ticketing_credentials WHERE id = NEW.credential_id;

        IF ticket_event_id IS DISTINCT FROM product_access_event_id OR
           ticket_event_id IS DISTINCT FROM event_date_event_id OR
           product_access_event_date_id IS DISTINCT FROM NEW.event_date_id OR
           credential_ticket_id IS DISTINCT FROM NEW.ticket_id THEN
          RAISE EXCEPTION 'ticketing_checkin_log_event_scope' USING ERRCODE = '23514';
        END IF;

        IF NEW.scanner_device_assignment_id IS NOT NULL THEN
          SELECT event_id INTO assignment_event_id
          FROM ticketing_scanner_device_assignments
          WHERE id = NEW.scanner_device_assignment_id;
          IF assignment_event_id IS DISTINCT FROM ticket_event_id THEN
            RAISE EXCEPTION 'ticketing_checkin_log_assignment_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.scan_upload_id IS NOT NULL THEN
          SELECT scanner_device_assignment_id INTO upload_assignment_id
          FROM ticketing_scan_uploads WHERE id = NEW.scan_upload_id;
          IF upload_assignment_id IS DISTINCT FROM NEW.scanner_device_assignment_id THEN
            RAISE EXCEPTION 'ticketing_checkin_log_upload_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.access_zone_id IS NOT NULL THEN
          SELECT event_id, event_date_id INTO zone_event_id, zone_event_date_id
          FROM events_access_zones WHERE id = NEW.access_zone_id;
          IF zone_event_id IS DISTINCT FROM ticket_event_id OR
             (zone_event_date_id IS NOT NULL AND zone_event_date_id IS DISTINCT FROM NEW.event_date_id) THEN
            RAISE EXCEPTION 'ticketing_checkin_log_zone_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.overrides_checkin_log_id IS NOT NULL THEN
          SELECT result, ticket_id INTO override_result, override_ticket_id
          FROM ticketing_checkin_logs WHERE id = NEW.overrides_checkin_log_id;
          IF override_result IS DISTINCT FROM 'identity_mismatch' OR
             override_ticket_id IS DISTINCT FROM NEW.ticket_id THEN
            RAISE EXCEPTION 'ticketing_checkin_log_override_scope' USING ERRCODE = '23514';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER trg_ticketing_checkin_log_scope
      BEFORE INSERT OR UPDATE ON ticketing_checkin_logs
      FOR EACH ROW EXECUTE FUNCTION ticketing_checkin_log_scope();

      CREATE FUNCTION ticketing_checkin_log_append_only() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'ticketing_checkin_logs_append_only' USING ERRCODE = '40001';
      END;
      $$;

      CREATE TRIGGER trg_ticketing_checkin_log_append_only
      BEFORE UPDATE OR DELETE ON ticketing_checkin_logs
      FOR EACH ROW EXECUTE FUNCTION ticketing_checkin_log_append_only();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_ticketing_checkin_log_append_only ON ticketing_checkin_logs;
      DROP TRIGGER IF EXISTS trg_ticketing_checkin_log_scope ON ticketing_checkin_logs;
      DROP FUNCTION IF EXISTS ticketing_checkin_log_append_only();
      DROP FUNCTION IF EXISTS ticketing_checkin_log_scope();
    SQL
    drop_table :ticketing_checkin_logs
  end

  private

  def quoted_values(values)
    values.map { |value| connection.quote(value) }.join(",")
  end
end
