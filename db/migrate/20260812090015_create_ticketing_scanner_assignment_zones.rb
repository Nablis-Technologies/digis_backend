# frozen_string_literal: true

class CreateTicketingScannerAssignmentZones < ActiveRecord::Migration[8.1]
  def up
    create_table :ticketing_scanner_assignment_zones, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :scanner_device_assignment_id, null: false
      t.uuid :access_zone_id, null: false

      t.timestamps
    end

    add_index :ticketing_scanner_assignment_zones,
              %i[scanner_device_assignment_id access_zone_id],
              unique: true,
              name: "idx_scanner_assignment_zones_unique"
    add_index :ticketing_scanner_assignment_zones, :access_zone_id

    add_foreign_key :ticketing_scanner_assignment_zones,
                    :ticketing_scanner_device_assignments,
                    column: :scanner_device_assignment_id
    add_foreign_key :ticketing_scanner_assignment_zones, :events_access_zones,
                    column: :access_zone_id

    execute <<~SQL
      CREATE FUNCTION ticketing_scanner_assignment_zone_scope() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        assignment_event_id uuid;
        zone_event_id uuid;
      BEGIN
        SELECT event_id INTO assignment_event_id
        FROM ticketing_scanner_device_assignments
        WHERE id = NEW.scanner_device_assignment_id;

        SELECT event_id INTO zone_event_id
        FROM events_access_zones
        WHERE id = NEW.access_zone_id;

        IF assignment_event_id IS DISTINCT FROM zone_event_id THEN
          RAISE EXCEPTION 'ticketing_scanner_assignment_zone_event_scope'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER trg_ticketing_scanner_assignment_zone_scope
      BEFORE INSERT OR UPDATE ON ticketing_scanner_assignment_zones
      FOR EACH ROW EXECUTE FUNCTION ticketing_scanner_assignment_zone_scope();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_ticketing_scanner_assignment_zone_scope
        ON ticketing_scanner_assignment_zones;
      DROP FUNCTION IF EXISTS ticketing_scanner_assignment_zone_scope();
    SQL
    drop_table :ticketing_scanner_assignment_zones
  end
end
