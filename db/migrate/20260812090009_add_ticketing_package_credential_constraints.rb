# frozen_string_literal: true

# Adds the cross-row guarantees that ordinary foreign keys and partial unique
# indexes cannot express: event scope, current-generation ownership, contiguous
# package slots, and complete group/delegated credential cardinality at commit.
class AddTicketingPackageCredentialConstraints < ActiveRecord::Migration[8.1]
  def up
    add_foreign_key :ticketing_tickets, :ticketing_credential_generations,
      column: :current_credential_generation_id,
      deferrable: :deferred
    add_foreign_key :ticketing_registration_answers, :ticketing_admission_slots,
      column: :admission_slot_id,
      deferrable: :deferred
    add_foreign_key :ticketing_registration_consent_requirements, :ticketing_admission_slots,
      column: :admission_slot_id,
      deferrable: :deferred
    add_foreign_key :ticketing_purchase_limit_allocations, :ticketing_tickets,
      column: :ticket_id,
      deferrable: :deferred

    execute <<~SQL
      CREATE OR REPLACE FUNCTION ticketing_credential_shape_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        generation_mode text;
        expected_ticket_id uuid;
        current_generation_id uuid;
        current_generation_status text;
        ticket_event_id uuid;
        duplicate_count integer;
        invalid_position_count integer;
      BEGIN
        SELECT mode, ticket_id
          INTO generation_mode, expected_ticket_id
          FROM ticketing_credential_generations
         WHERE id = NEW.credential_generation_id;

        IF NEW.ticket_id IS DISTINCT FROM expected_ticket_id THEN
          RAISE EXCEPTION 'credential ticket and generation do not match'
            USING ERRCODE = '23514';
        END IF;

        SELECT event_id, current_credential_generation_id
          INTO ticket_event_id, current_generation_id
          FROM ticketing_tickets
         WHERE id = NEW.ticket_id;

        IF NEW.event_id IS DISTINCT FROM ticket_event_id THEN
          RAISE EXCEPTION 'credential event and ticket do not match'
            USING ERRCODE = '23514';
        END IF;

        SELECT status
          INTO current_generation_status
          FROM ticketing_credential_generations
         WHERE id = current_generation_id;

        IF NEW.status IN ('active', 'pending_claim', 'pending_requirements') AND
           (current_generation_id IS DISTINCT FROM NEW.credential_generation_id OR
            current_generation_status IS DISTINCT FROM 'active') THEN
          RAISE EXCEPTION 'usable credentials must belong to the ticket current active generation'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.type = 'package' AND generation_mode IS DISTINCT FROM 'group' THEN
          RAISE EXCEPTION 'package credentials require group generations'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.type = 'individual' AND generation_mode IS DISTINCT FROM 'delegated' THEN
          RAISE EXCEPTION 'individual credentials require delegated generations'
            USING ERRCODE = '23514';
        END IF;

        SELECT COUNT(*) - COUNT(DISTINCT position), COUNT(*) FILTER (WHERE position <= 0)
          INTO duplicate_count, invalid_position_count
          FROM unnest(NEW.slot_positions) AS positions(position);

        IF duplicate_count <> 0 OR invalid_position_count <> 0 THEN
          RAISE EXCEPTION 'credential slot positions must be positive and unique'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.type = 'individual' AND cardinality(NEW.slot_positions) <> 1 THEN
          RAISE EXCEPTION 'individual credentials must contain one slot position'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.admission_slot_id IS NOT NULL AND NOT EXISTS (
          SELECT 1
            FROM ticketing_admission_slots slot
           WHERE slot.id = NEW.admission_slot_id
             AND slot.ticket_id = NEW.ticket_id
             AND slot.position = NEW.slot_positions[1]
        ) THEN
          RAISE EXCEPTION 'credential admission slot does not match ticket position'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION ticketing_admission_slot_shape_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        expected_admission_count integer;
      BEGIN
        SELECT admissions_per_unit_snapshot
          INTO expected_admission_count
          FROM ticketing_tickets
         WHERE id = NEW.ticket_id;

        IF NEW.position > expected_admission_count THEN
          RAISE EXCEPTION 'admission slot position exceeds the package snapshot'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      DROP TRIGGER IF EXISTS trg_ticketing_admission_slot_shape_guard
        ON ticketing_admission_slots;
      CREATE TRIGGER trg_ticketing_admission_slot_shape_guard
        BEFORE INSERT OR UPDATE ON ticketing_admission_slots
        FOR EACH ROW EXECUTE FUNCTION ticketing_admission_slot_shape_guard();

      CREATE OR REPLACE FUNCTION ticketing_ticket_scope_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        product_event_id uuid;
        product_type text;
        registration_event_id uuid;
        order_event_id uuid;
        acquisition_order_event_id uuid;
        generation_ticket_id uuid;
        generation_mode text;
        generation_version integer;
        generation_status text;
      BEGIN
        SELECT event_id, type INTO product_event_id, product_type
          FROM catalog_event_products
         WHERE id = NEW.event_product_id;
        IF product_event_id IS DISTINCT FROM NEW.event_id OR product_type NOT IN ('ticket', 'parking') THEN
          RAISE EXCEPTION 'ticket product and event do not match'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.registration_id IS NOT NULL THEN
          SELECT event_id INTO registration_event_id
            FROM ticketing_registrations
           WHERE id = NEW.registration_id;
          IF registration_event_id IS DISTINCT FROM NEW.event_id THEN
            RAISE EXCEPTION 'ticket registration and event do not match'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.order_item_id IS NOT NULL THEN
          SELECT order_record.event_id INTO order_event_id
            FROM orders_order_items item
            JOIN orders_orders order_record ON order_record.id = item.order_id
           WHERE item.id = NEW.order_item_id;
          IF order_event_id IS DISTINCT FROM NEW.event_id THEN
            RAISE EXCEPTION 'ticket order item and event do not match'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.current_acquisition_order_item_id IS NOT NULL THEN
          SELECT order_record.event_id INTO acquisition_order_event_id
            FROM orders_order_items item
            JOIN orders_orders order_record ON order_record.id = item.order_id
           WHERE item.id = NEW.current_acquisition_order_item_id;
          IF acquisition_order_event_id IS DISTINCT FROM NEW.event_id THEN
            RAISE EXCEPTION 'ticket acquisition order item and event do not match'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.current_credential_generation_id IS NOT NULL THEN
          SELECT ticket_id, mode, version, status
            INTO generation_ticket_id, generation_mode, generation_version, generation_status
            FROM ticketing_credential_generations
           WHERE id = NEW.current_credential_generation_id;
          IF generation_ticket_id IS DISTINCT FROM NEW.id OR
             generation_mode IS DISTINCT FROM NEW.credential_mode OR
             generation_version IS DISTINCT FROM NEW.credential_version OR
             (generation_status IS DISTINCT FROM 'active' AND
              NOT (NEW.status IN ('void', 'refunded') AND generation_status = 'revoked')) THEN
            RAISE EXCEPTION 'ticket current credential generation does not match the ticket'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;

      DROP TRIGGER IF EXISTS trg_ticketing_ticket_scope_guard
        ON ticketing_tickets;
      CREATE TRIGGER trg_ticketing_ticket_scope_guard
        BEFORE INSERT OR UPDATE ON ticketing_tickets
        FOR EACH ROW EXECUTE FUNCTION ticketing_ticket_scope_guard();

      DROP TRIGGER IF EXISTS trg_ticketing_credential_shape_guard
        ON ticketing_credentials;
      CREATE TRIGGER trg_ticketing_credential_shape_guard
        BEFORE INSERT OR UPDATE ON ticketing_credentials
        FOR EACH ROW EXECUTE FUNCTION ticketing_credential_shape_guard();

      CREATE OR REPLACE FUNCTION ticketing_credential_generation_cardinality_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        generation_id uuid;
        generation_mode text;
        generation_ticket_id uuid;
        expected_slot_count integer;
        package_count integer;
        individual_count integer;
        invalid_positions boolean;
      BEGIN
        generation_id := COALESCE(NEW.credential_generation_id, OLD.credential_generation_id);

        SELECT mode, ticket_id
          INTO generation_mode, generation_ticket_id
          FROM ticketing_credential_generations
         WHERE id = generation_id;

        SELECT COUNT(*)
          INTO expected_slot_count
          FROM ticketing_admission_slots
         WHERE ticket_id = generation_ticket_id;

        IF expected_slot_count <> (
          SELECT admissions_per_unit_snapshot
            FROM ticketing_tickets
           WHERE id = generation_ticket_id
        ) OR EXISTS (
          SELECT 1
            FROM ticketing_admission_slots slot
           WHERE slot.ticket_id = generation_ticket_id
             AND slot.position NOT BETWEEN 1 AND (
               SELECT admissions_per_unit_snapshot
                 FROM ticketing_tickets
                WHERE id = generation_ticket_id
             )
        ) THEN
          RAISE EXCEPTION 'package admission slots must match the package snapshot'
            USING ERRCODE = '23514';
        END IF;

        SELECT COUNT(*) FILTER (WHERE type = 'package'),
               COUNT(*) FILTER (WHERE type = 'individual')
          INTO package_count, individual_count
          FROM ticketing_credentials
         WHERE credential_generation_id = generation_id;

        IF generation_mode = 'group' THEN
          IF package_count <> 1 OR individual_count <> 0 THEN
            RAISE EXCEPTION 'group generations require one package credential only'
              USING ERRCODE = '23514';
          END IF;

          SELECT EXISTS (
            SELECT 1
              FROM ticketing_credentials credential
             WHERE credential.credential_generation_id = generation_id
               AND (cardinality(credential.slot_positions) <> expected_slot_count OR
                    EXISTS (
                      SELECT 1
                        FROM ticketing_admission_slots slot
                       WHERE slot.ticket_id = generation_ticket_id
                         AND NOT (slot.position = ANY (credential.slot_positions))
                    ))
          )
            INTO invalid_positions;
          IF invalid_positions THEN
            RAISE EXCEPTION 'group credential must cover every admission slot'
              USING ERRCODE = '23514';
          END IF;
        ELSIF generation_mode = 'delegated' THEN
          IF package_count <> 0 OR individual_count <> expected_slot_count THEN
            RAISE EXCEPTION 'delegated generations require one individual credential per slot'
              USING ERRCODE = '23514';
          END IF;

          IF EXISTS (
            SELECT 1
              FROM ticketing_admission_slots slot
             WHERE slot.ticket_id = generation_ticket_id
               AND NOT EXISTS (
                 SELECT 1
                   FROM ticketing_credentials credential
                  WHERE credential.credential_generation_id = generation_id
                    AND credential.type = 'individual'
                    AND credential.admission_slot_id = slot.id
               )
          ) THEN
            RAISE EXCEPTION 'delegated generations must cover every admission slot'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        RETURN NULL;
      END;
      $$;

      DROP TRIGGER IF EXISTS trg_ticketing_credential_generation_cardinality
        ON ticketing_credentials;
      CREATE CONSTRAINT TRIGGER trg_ticketing_credential_generation_cardinality
        AFTER INSERT OR UPDATE OR DELETE ON ticketing_credentials
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION ticketing_credential_generation_cardinality_guard();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_ticketing_credential_generation_cardinality
        ON ticketing_credentials;
      DROP TRIGGER IF EXISTS trg_ticketing_credential_shape_guard
        ON ticketing_credentials;
      DROP TRIGGER IF EXISTS trg_ticketing_ticket_scope_guard
        ON ticketing_tickets;
      DROP TRIGGER IF EXISTS trg_ticketing_admission_slot_shape_guard
        ON ticketing_admission_slots;
      DROP FUNCTION IF EXISTS ticketing_credential_generation_cardinality_guard();
      DROP FUNCTION IF EXISTS ticketing_credential_shape_guard();
      DROP FUNCTION IF EXISTS ticketing_ticket_scope_guard();
      DROP FUNCTION IF EXISTS ticketing_admission_slot_shape_guard();
    SQL

    remove_foreign_key :ticketing_purchase_limit_allocations, column: :ticket_id
    remove_foreign_key :ticketing_registration_consent_requirements,
      column: :admission_slot_id
    remove_foreign_key :ticketing_registration_answers, column: :admission_slot_id
    remove_foreign_key :ticketing_tickets, column: :current_credential_generation_id
  end
end
