# frozen_string_literal: true

class CreateTicketingRegistrationConsentRequirements < ActiveRecord::Migration[8.1]
  def up
    create_table :ticketing_registration_consent_requirements, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :registration_id, null: false
      t.uuid :consent_document_version_id, null: false
      t.boolean :required, null: false, default: true
      t.string :acceptance_scope, null: false
      t.integer :package_unit_number
      t.integer :admission_position, limit: 2
      t.uuid :admission_slot_id
      t.uuid :subject_user_id
      t.string :status, null: false, default: "pending"
      t.uuid :supersedes_requirement_id
      t.string :required_reason, null: false, default: "initial_submission"
      t.uuid :required_by_id
      t.timestamptz :required_at, null: false
      t.timestamptz :superseded_at
      t.timestamptz :expired_at
      t.timestamps
    end

    add_check_constraint :ticketing_registration_consent_requirements,
      "acceptance_scope IN ('buyer','admission_slot')",
      name: "ticketing_consent_requirements_scope_check"
    add_check_constraint :ticketing_registration_consent_requirements,
      "status IN ('pending','accepted','withdrawn','superseded','expired')",
      name: "ticketing_consent_requirements_status_check"
    add_check_constraint :ticketing_registration_consent_requirements,
      "required_reason IN ('initial_submission','reconsent')",
      name: "ticketing_consent_requirements_reason_check"
    add_check_constraint :ticketing_registration_consent_requirements,
      "((acceptance_scope = 'buyer' AND package_unit_number IS NULL AND " \
        "admission_position IS NULL AND admission_slot_id IS NULL AND subject_user_id IS NOT NULL) OR " \
        "(acceptance_scope = 'admission_slot' AND package_unit_number IS NOT NULL AND " \
        "package_unit_number > 0 AND admission_position IS NOT NULL AND admission_position > 0 " \
        "AND admission_slot_id IS NULL))",
      name: "ticketing_consent_requirements_coordinate_check"
    add_check_constraint :ticketing_registration_consent_requirements,
      "((status = 'superseded' AND superseded_at IS NOT NULL AND expired_at IS NULL) OR " \
        "(status = 'expired' AND expired_at IS NOT NULL AND superseded_at IS NULL) OR " \
        "(status NOT IN ('superseded','expired') AND superseded_at IS NULL AND expired_at IS NULL))",
      name: "ticketing_consent_requirements_terminal_at_check"
    add_check_constraint :ticketing_registration_consent_requirements,
      "(required_reason = 'initial_submission' OR required_by_id IS NOT NULL)",
      name: "ticketing_consent_requirements_required_by_check"
    add_check_constraint :ticketing_registration_consent_requirements,
      "(status NOT IN ('accepted','withdrawn') OR subject_user_id IS NOT NULL)",
      name: "ticketing_consent_requirements_subject_check"

    add_index :ticketing_registration_consent_requirements,
      %i[registration_id consent_document_version_id],
      unique: true,
      where: "acceptance_scope = 'buyer' AND status IN ('pending','accepted')",
      name: "idx_current_buyer_consent_requirement"
    add_index :ticketing_registration_consent_requirements,
      %i[registration_id consent_document_version_id package_unit_number admission_position],
      unique: true,
      where: "acceptance_scope = 'admission_slot' AND status IN ('pending','accepted')",
      name: "idx_current_slot_consent_requirement"
    add_index :ticketing_registration_consent_requirements, :registration_id,
      name: "idx_consent_requirements_registration"
    add_index :ticketing_registration_consent_requirements, :consent_document_version_id,
      name: "idx_consent_requirements_version"
    add_index :ticketing_registration_consent_requirements, :admission_slot_id,
      name: "idx_consent_requirements_admission_slot"
    add_index :ticketing_registration_consent_requirements, :subject_user_id,
      name: "idx_consent_requirements_subject"
    add_index :ticketing_registration_consent_requirements, :supersedes_requirement_id,
      name: "idx_consent_requirements_supersedes"
    add_index :ticketing_registration_consent_requirements, %i[status required_at],
      name: "idx_consent_requirements_due"

    add_foreign_key :ticketing_registration_consent_requirements,
      :ticketing_registrations, column: :registration_id, on_delete: :restrict
    add_foreign_key :ticketing_registration_consent_requirements,
      :events_consent_document_versions, column: :consent_document_version_id, on_delete: :restrict
    add_foreign_key :ticketing_registration_consent_requirements,
      :core_users, column: :subject_user_id, on_delete: :restrict
    add_foreign_key :ticketing_registration_consent_requirements,
      :ticketing_registration_consent_requirements,
      column: :supersedes_requirement_id, on_delete: :restrict
    add_foreign_key :ticketing_registration_consent_requirements,
      :core_users, column: :required_by_id, on_delete: :restrict

    execute <<~SQL
      CREATE OR REPLACE FUNCTION ticketing_registration_consent_requirement_integrity()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        registration_event_id uuid;
        registration_ticket_type_id uuid;
        document_event_id uuid;
        document_active boolean;
        version_status text;
        version_scope text;
        version_required boolean;
        ticket_event_id uuid;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'registration consent requirements are historical evidence'
            USING ERRCODE = '40001';
        END IF;

        IF TG_OP = 'INSERT' AND NEW.status IS DISTINCT FROM 'pending' THEN
          RAISE EXCEPTION 'new consent requirements must start pending'
            USING ERRCODE = '23514';
        END IF;

        IF TG_OP = 'UPDATE' THEN
          IF NEW.registration_id IS DISTINCT FROM OLD.registration_id OR
             NEW.consent_document_version_id IS DISTINCT FROM OLD.consent_document_version_id OR
             NEW.required IS DISTINCT FROM OLD.required OR
             NEW.acceptance_scope IS DISTINCT FROM OLD.acceptance_scope OR
             NEW.package_unit_number IS DISTINCT FROM OLD.package_unit_number OR
             NEW.admission_position IS DISTINCT FROM OLD.admission_position OR
             NEW.admission_slot_id IS DISTINCT FROM OLD.admission_slot_id OR
             NEW.required_reason IS DISTINCT FROM OLD.required_reason OR
             NEW.required_by_id IS DISTINCT FROM OLD.required_by_id OR
             NEW.required_at IS DISTINCT FROM OLD.required_at OR
             NEW.supersedes_requirement_id IS DISTINCT FROM OLD.supersedes_requirement_id THEN
            RAISE EXCEPTION 'consent requirement snapshots and lineage are immutable'
              USING ERRCODE = '23514';
          END IF;

           IF NEW.subject_user_id IS DISTINCT FROM OLD.subject_user_id AND OLD.status <> 'pending' THEN
            RAISE EXCEPTION 'consent requirement subjects are immutable after acceptance begins'
              USING ERRCODE = '23514';
           END IF;

           IF OLD.superseded_at IS NOT NULL AND NEW.superseded_at IS DISTINCT FROM OLD.superseded_at THEN
             RAISE EXCEPTION 'superseded consent requirement timestamps are immutable'
               USING ERRCODE = '23514';
           END IF;

           IF OLD.expired_at IS NOT NULL AND NEW.expired_at IS DISTINCT FROM OLD.expired_at THEN
             RAISE EXCEPTION 'expired consent requirement timestamps are immutable'
               USING ERRCODE = '23514';
           END IF;

          IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
            (OLD.status = 'pending' AND NEW.status IN ('pending','accepted','withdrawn','superseded','expired')) OR
            (OLD.status = 'accepted' AND NEW.status IN ('accepted','withdrawn','superseded')) OR
            (OLD.status = 'withdrawn' AND NEW.status = 'withdrawn') OR
            (OLD.status = 'superseded' AND NEW.status = 'superseded') OR
            (OLD.status = 'expired' AND NEW.status = 'expired')
          ) THEN
            RAISE EXCEPTION 'invalid consent requirement status transition'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        SELECT registration.event_id, registration.ticket_type_id
          INTO registration_event_id, registration_ticket_type_id
          FROM ticketing_registrations registration
         WHERE registration.id = NEW.registration_id;

        SELECT document.event_id, document.active, version.status,
               version.acceptance_scope, version.required
          INTO document_event_id, document_active, version_status,
               version_scope, version_required
          FROM events_consent_document_versions version
          JOIN events_consent_documents document
            ON document.id = version.consent_document_id
         WHERE version.id = NEW.consent_document_version_id;

        IF registration_event_id IS DISTINCT FROM document_event_id THEN
          RAISE EXCEPTION 'consent requirements must reference one event'
            USING ERRCODE = '23514';
        END IF;
        IF TG_OP = 'INSERT' THEN
          IF document_active IS DISTINCT FROM TRUE OR version_status IS DISTINCT FROM 'published' OR EXISTS (
            SELECT 1
              FROM events_consent_document_versions newer_version
             WHERE newer_version.consent_document_id = (
               SELECT consent_document_id
                 FROM events_consent_document_versions
                WHERE id = NEW.consent_document_version_id
             )
               AND newer_version.status = 'published'
               AND newer_version.id <> NEW.consent_document_version_id
          ) THEN
            RAISE EXCEPTION 'new consent requirements must use the current published active version'
              USING ERRCODE = '23514';
          END IF;
        ELSIF document_active IS DISTINCT FROM TRUE OR version_status IS NULL OR
              version_status NOT IN ('published','retired') THEN
          RAISE EXCEPTION 'existing consent requirements must retain a published or retired version'
            USING ERRCODE = '23514';
        END IF;
        IF version_scope IS DISTINCT FROM NEW.acceptance_scope OR
           version_required IS DISTINCT FROM NEW.required THEN
          RAISE EXCEPTION 'consent requirement snapshots must match the document version'
            USING ERRCODE = '23514';
        END IF;

        SELECT product.event_id
          INTO ticket_event_id
          FROM ticketing_ticket_types ticket_type
          JOIN catalog_event_products product ON product.id = ticket_type.event_product_id
         WHERE ticket_type.id = registration_ticket_type_id;
        IF ticket_event_id IS DISTINCT FROM registration_event_id THEN
          RAISE EXCEPTION 'consent requirements must use a ticket type from the registration event'
            USING ERRCODE = '23514';
        END IF;
        IF EXISTS (
          SELECT 1
            FROM events_consent_document_products scoped_product
           WHERE scoped_product.consent_document_id = (
             SELECT consent_document_id
               FROM events_consent_document_versions
              WHERE id = NEW.consent_document_version_id
           )
        ) AND NOT EXISTS (
          SELECT 1
            FROM events_consent_document_products scoped_product
           WHERE scoped_product.consent_document_id = (
             SELECT consent_document_id
               FROM events_consent_document_versions
              WHERE id = NEW.consent_document_version_id
           )
             AND scoped_product.ticket_type_id = registration_ticket_type_id
        ) THEN
          RAISE EXCEPTION 'consent requirements must match the document ticket-product scope'
            USING ERRCODE = '23514';
        END IF;
        IF NEW.acceptance_scope = 'buyer' THEN
          IF NEW.subject_user_id IS DISTINCT FROM (
            SELECT user_id FROM ticketing_registrations WHERE id = NEW.registration_id
          ) THEN
            RAISE EXCEPTION 'buyer consent requirements must belong to the registration user'
              USING ERRCODE = '23514';
          END IF;
        ELSE
          IF NEW.package_unit_number > (
            SELECT package_quantity FROM ticketing_registrations WHERE id = NEW.registration_id
          ) OR NEW.admission_position > (
            SELECT admissions_per_unit_snapshot FROM ticketing_registrations WHERE id = NEW.registration_id
          ) THEN
            RAISE EXCEPTION 'consent requirement coordinates exceed the registration snapshot'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER trg_ticketing_registration_consent_requirement_integrity
        BEFORE INSERT OR UPDATE OR DELETE ON ticketing_registration_consent_requirements
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_consent_requirement_integrity();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_ticketing_registration_consent_requirement_integrity
        ON ticketing_registration_consent_requirements;
      DROP FUNCTION IF EXISTS ticketing_registration_consent_requirement_integrity();
    SQL
    drop_table :ticketing_registration_consent_requirements
  end
end
