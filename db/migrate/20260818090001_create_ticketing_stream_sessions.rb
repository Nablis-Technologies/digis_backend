# frozen_string_literal: true

class CreateTicketingStreamSessions < ActiveRecord::Migration[8.1]
  def up
    create_table :ticketing_stream_sessions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :ticket_id, null: false
      t.uuid :event_stream_id, null: false
      t.uuid :user_id, null: false
      t.string :device_id, null: false
      t.string :session_token_digest, limit: 64, null: false
      t.string :status, null: false, default: "active"
      t.timestamptz :expires_at, null: false
      t.timestamptz :last_seen_at
      t.timestamptz :revoked_at

      t.timestamps
    end

    add_index :ticketing_stream_sessions, :session_token_digest, unique: true
    add_index :ticketing_stream_sessions,
              %i[ticket_id event_stream_id status expires_at],
              name: "idx_stream_session_authorization"

    add_check_constraint :ticketing_stream_sessions,
                         "status IN ('active','expired','revoked')",
                         name: "ticketing_stream_sessions_status_check"
    add_check_constraint :ticketing_stream_sessions,
                         "device_id = btrim(device_id) AND btrim(device_id) <> ''",
                         name: "ticketing_stream_sessions_device_id_check"
    add_check_constraint :ticketing_stream_sessions,
                         "session_token_digest ~ '^[0-9a-f]{64}$'",
                         name: "ticketing_stream_sessions_digest_check"
    add_check_constraint :ticketing_stream_sessions,
                         "expires_at > created_at",
                         name: "ticketing_stream_sessions_expiry_check"
    add_check_constraint :ticketing_stream_sessions,
                         "((status = 'revoked' AND revoked_at IS NOT NULL) OR " \
                           "(status <> 'revoked' AND revoked_at IS NULL))",
                         name: "ticketing_stream_sessions_revocation_check"

    add_foreign_key :ticketing_stream_sessions, :ticketing_tickets,
                    column: :ticket_id
    add_foreign_key :ticketing_stream_sessions, :events_event_streams,
                    column: :event_stream_id
    add_foreign_key :ticketing_stream_sessions, :core_users,
                    column: :user_id

    execute <<~SQL
      CREATE FUNCTION ticketing_stream_session_same_event() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        ticket_event_id uuid;
        stream_event_id uuid;
      BEGIN
        SELECT event_id INTO ticket_event_id
        FROM ticketing_tickets
        WHERE id = NEW.ticket_id;

        SELECT event_date.event_id INTO stream_event_id
        FROM events_event_streams stream
        JOIN events_event_dates event_date ON event_date.id = stream.event_date_id
        WHERE stream.id = NEW.event_stream_id;

        IF ticket_event_id IS DISTINCT FROM stream_event_id THEN
          RAISE EXCEPTION 'ticketing_stream_session_event_scope' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE CONSTRAINT TRIGGER trg_ticketing_stream_session_same_event
        AFTER INSERT OR UPDATE ON ticketing_stream_sessions
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION ticketing_stream_session_same_event();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_ticketing_stream_session_same_event
        ON ticketing_stream_sessions;
      DROP FUNCTION IF EXISTS ticketing_stream_session_same_event();
    SQL

    drop_table :ticketing_stream_sessions
  end
end
