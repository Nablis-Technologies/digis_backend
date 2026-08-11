class CreateTicketingAttendeeExports < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_attendee_exports, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :event, null: false, type: :uuid, foreign_key: { to_table: :events_events }
      t.references :requested_by, null: false, type: :uuid, foreign_key: { to_table: :core_users }
      t.string :status, null: false
      t.string :row_mode, null: false
      t.string :format_version, null: false
      t.jsonb :field_keys
      t.jsonb :filters
      t.string :field_set_digest, null: false
      t.string :filter_digest, null: false
      t.string :reason_code, null: false
      t.datetime :data_cutoff_at, null: false
      t.integer :row_count
      t.string :file_sha256
      t.string :idempotency_key_digest, null: false
      t.string :request_fingerprint, null: false
      t.string :digest_key_version, null: false
      t.datetime :processing_started_at
      t.integer :attempt_count, null: false, default: 0
      t.datetime :ready_at
      t.datetime :failed_at
      t.datetime :expiring_at
      t.datetime :expired_at
      t.datetime :expires_at, null: false
      t.datetime :last_download_authorized_at
      t.string :failure_code
      t.integer :lock_version, null: false, default: 0

      t.timestamps null: false
    end

    add_check_constraint :ticketing_attendee_exports,
      "status IN ('pending','processing','ready','failed','expiring','expired')",
      name: "ticketing_attendee_exports_status_check"
    add_check_constraint :ticketing_attendee_exports,
      "row_mode IN ('registration','admission')",
      name: "ticketing_attendee_exports_row_mode_check"
    add_check_constraint :ticketing_attendee_exports,
      "format_version = 'csv_v1'",
      name: "ticketing_attendee_exports_format_version_check"
    add_check_constraint :ticketing_attendee_exports,
      "reason_code IN ('event_operations','attendee_communication','dietary_accommodation','accessibility_accommodation','customer_support','legal_compliance')",
      name: "ticketing_attendee_exports_reason_code_check"
    add_check_constraint :ticketing_attendee_exports,
      "field_set_digest ~ '^[0-9a-f]{64}$'",
      name: "ticketing_attendee_exports_field_set_digest_check"
    add_check_constraint :ticketing_attendee_exports,
      "filter_digest ~ '^[0-9a-f]{64}$'",
      name: "ticketing_attendee_exports_filter_digest_check"
    add_check_constraint :ticketing_attendee_exports,
      "idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "ticketing_attendee_exports_idempotency_digest_check"
    add_check_constraint :ticketing_attendee_exports,
      "request_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "ticketing_attendee_exports_request_fingerprint_check"
    add_check_constraint :ticketing_attendee_exports,
      "digest_key_version ~ '^v[0-9]+$'",
      name: "ticketing_attendee_exports_digest_key_version_check"
    add_check_constraint :ticketing_attendee_exports,
      "file_sha256 IS NULL OR file_sha256 ~ '^[0-9a-f]{64}$'",
      name: "ticketing_attendee_exports_file_digest_shape_check"
    add_check_constraint :ticketing_attendee_exports,
      "field_keys IS NULL OR (jsonb_typeof(field_keys) = 'array' AND jsonb_array_length(field_keys) <= 100)",
      name: "ticketing_attendee_exports_field_keys_shape_check"
    add_check_constraint :ticketing_attendee_exports,
      "jsonb_typeof(filters) = 'object' OR filters IS NULL",
      name: "ticketing_attendee_exports_filters_shape_check"
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE FUNCTION ticketing_attendee_exports_filters_valid(filters jsonb)
          RETURNS boolean
          LANGUAGE plpgsql
          IMMUTABLE
          AS $$
          DECLARE
            filter_key text;
            filter_values text[];
          BEGIN
            IF filters IS NULL OR jsonb_typeof(filters) <> 'object' THEN
              RETURN filters IS NULL;
            END IF;

            IF EXISTS (
              SELECT 1
              FROM jsonb_object_keys(filters) AS keys(key)
              WHERE key NOT IN ('ticket_type_ids', 'access_event_date_ids', 'registration_statuses')
            ) THEN
              RETURN FALSE;
            END IF;

            FOREACH filter_key IN ARRAY ARRAY['ticket_type_ids', 'access_event_date_ids', 'registration_statuses'] LOOP
              CONTINUE WHEN NOT filters ? filter_key;
              IF jsonb_typeof(filters -> filter_key) <> 'array'
                 OR jsonb_array_length(filters -> filter_key) > 100 THEN
                RETURN FALSE;
              END IF;

              SELECT array_agg(value) INTO filter_values
              FROM jsonb_array_elements_text(filters -> filter_key) AS element(value);
              CONTINUE WHEN filter_values IS NULL;
              IF cardinality(filter_values) <> (
                SELECT count(DISTINCT value) FROM unnest(filter_values) AS items(value)
              ) THEN
                RETURN FALSE;
              END IF;
              IF filter_key IN ('ticket_type_ids', 'access_event_date_ids') AND EXISTS (
                SELECT 1 FROM unnest(filter_values) AS items(value)
                WHERE value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              ) THEN
                RETURN FALSE;
              END IF;
              IF filter_key = 'registration_statuses' AND EXISTS (
                SELECT 1 FROM unnest(filter_values) AS items(value)
                WHERE value NOT IN ('pending_payment','pending_approval','waitlisted','offered','confirmed','rejected','cancelled','expired')
              ) THEN
                RETURN FALSE;
              END IF;
            END LOOP;

            RETURN TRUE;
          END;
          $$;
        SQL
      end
      dir.down do
        execute "DROP FUNCTION IF EXISTS ticketing_attendee_exports_filters_valid(jsonb)"
      end
    end
    add_check_constraint :ticketing_attendee_exports,
      "ticketing_attendee_exports_filters_valid(filters)",
      name: "ticketing_attendee_exports_filter_contract_check"
    add_check_constraint :ticketing_attendee_exports,
      "failure_code IS NULL OR failure_code IN ('export_too_large','export_generation_failed','export_storage_unavailable')",
      name: "ticketing_attendee_exports_failure_code_check"
    add_check_constraint :ticketing_attendee_exports,
      "attempt_count BETWEEN 0 AND 3",
      name: "ticketing_attendee_exports_attempt_count_check"
    add_check_constraint :ticketing_attendee_exports,
      "row_count IS NULL OR row_count >= 0",
      name: "ticketing_attendee_exports_row_count_check"
    add_check_constraint :ticketing_attendee_exports,
      "expires_at > data_cutoff_at AND expires_at <= created_at + INTERVAL '24 hours'",
      name: "ticketing_attendee_exports_expiry_window_check"
    add_check_constraint :ticketing_attendee_exports,
      <<~SQL.squish,
        (status = 'pending' AND processing_started_at IS NULL AND ready_at IS NULL AND failed_at IS NULL AND expiring_at IS NULL AND expired_at IS NULL)
        OR (status = 'processing' AND processing_started_at IS NOT NULL AND ready_at IS NULL AND failed_at IS NULL AND expiring_at IS NULL AND expired_at IS NULL)
        OR (status = 'ready' AND processing_started_at IS NOT NULL AND ready_at IS NOT NULL AND failed_at IS NULL AND expiring_at IS NULL AND expired_at IS NULL AND row_count IS NOT NULL AND file_sha256 IS NOT NULL)
        OR (status = 'failed' AND processing_started_at IS NOT NULL AND ready_at IS NULL AND failed_at IS NOT NULL AND expiring_at IS NULL AND expired_at IS NULL)
        OR (status = 'expiring' AND processing_started_at IS NULL AND ready_at IS NULL AND failed_at IS NULL AND expiring_at IS NOT NULL AND expired_at IS NULL)
        OR (status = 'expired' AND processing_started_at IS NULL AND ready_at IS NULL AND failed_at IS NULL AND expiring_at IS NULL AND expired_at IS NOT NULL)
      SQL
      name: "ticketing_attendee_exports_state_timestamps_check"
    add_check_constraint :ticketing_attendee_exports,
      "(status = 'expired' AND field_keys IS NULL AND filters IS NULL AND failure_code IS NULL) OR (status <> 'expired' AND field_keys IS NOT NULL AND filters IS NOT NULL)",
      name: "ticketing_attendee_exports_payload_state_check"

    add_index :ticketing_attendee_exports, :status
    add_index :ticketing_attendee_exports, :expires_at
    add_index :ticketing_attendee_exports, :idempotency_key_digest, unique: true
  end
end
