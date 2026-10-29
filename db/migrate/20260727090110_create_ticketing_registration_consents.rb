# frozen_string_literal: true

class CreateTicketingRegistrationConsents < ActiveRecord::Migration[8.1]
  def up
    create_table :ticketing_registration_consents, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :registration_consent_requirement_id, null: false
      t.uuid :registration_id, null: false
      t.uuid :accepted_by_user_id
      t.string :signer_role, null: false
      t.string :acceptance_method, null: false, default: "otp"
      t.string :content_sha256, null: false, limit: 64
      t.string :evidence_digest, limit: 64
      t.string :idempotency_key_digest, limit: 64
      t.uuid :request_uuid
      t.uuid :retention_policy_id, null: false
      t.timestamptz :retain_until
      t.timestamptz :accepted_at, null: false
      t.timestamptz :erased_at
      t.timestamps
    end

    add_check_constraint :ticketing_registration_consents,
      "signer_role IN ('buyer','attendee')",
      name: "ticketing_registration_consents_signer_role_check"
    add_check_constraint :ticketing_registration_consents,
      "acceptance_method IN ('checkbox','otp')",
      name: "ticketing_registration_consents_acceptance_method_check"
    add_check_constraint :ticketing_registration_consents,
      "content_sha256 ~ '^[0-9a-f]{64}$' AND (evidence_digest IS NULL OR evidence_digest ~ '^[0-9a-f]{64}$')",
      name: "ticketing_registration_consents_digest_check"
    add_check_constraint :ticketing_registration_consents,
      "idempotency_key_digest IS NULL OR idempotency_key_digest ~ '^[0-9a-f]{64}$'",
      name: "ticketing_registration_consents_idempotency_digest_check"
    add_check_constraint :ticketing_registration_consents,
      "retain_until IS NULL OR retain_until > accepted_at",
      name: "ticketing_registration_consents_retention_window_check"
    add_check_constraint :ticketing_registration_consents,
      "erased_at IS NULL OR erased_at >= accepted_at",
      name: "ticketing_registration_consents_erasure_time_check"
    add_check_constraint :ticketing_registration_consents,
      "((erased_at IS NULL AND accepted_by_user_id IS NOT NULL AND evidence_digest IS NOT NULL AND " \
        "idempotency_key_digest IS NOT NULL AND request_uuid IS NOT NULL) OR " \
        "(erased_at IS NOT NULL AND accepted_by_user_id IS NULL AND evidence_digest IS NULL AND " \
        "idempotency_key_digest IS NULL AND request_uuid IS NULL))",
      name: "ticketing_registration_consents_erasure_payload_check"

    add_index :ticketing_registration_consents, :registration_consent_requirement_id,
      unique: true,
      name: "idx_one_consent_acceptance_per_requirement"
    add_index :ticketing_registration_consents, :request_uuid,
      unique: true,
      name: "idx_unique_registration_consent_request_uuid"
    add_index :ticketing_registration_consents, :idempotency_key_digest,
      unique: true,
      name: "idx_unique_registration_consent_idempotency_key"
    add_index :ticketing_registration_consents, %i[registration_id accepted_at],
      name: "idx_registration_consents_by_registration"
    add_index :ticketing_registration_consents, %i[accepted_by_user_id accepted_at],
      name: "idx_registration_consents_by_signer"
    add_index :ticketing_registration_consents, :retention_policy_id,
      name: "idx_registration_consents_retention_policy"

    add_foreign_key :ticketing_registration_consents,
      :ticketing_registration_consent_requirements,
      column: :registration_consent_requirement_id, on_delete: :restrict
    add_foreign_key :ticketing_registration_consents,
      :ticketing_registrations, column: :registration_id, on_delete: :restrict
    add_foreign_key :ticketing_registration_consents,
      :core_users, column: :accepted_by_user_id, on_delete: :restrict
    add_foreign_key :ticketing_registration_consents,
      :core_data_retention_policies, column: :retention_policy_id, on_delete: :restrict

    execute <<~SQL
      CREATE OR REPLACE FUNCTION ticketing_registration_consent_append_only()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        retention_action text;
      BEGIN
        IF TG_OP = 'DELETE' OR OLD.erased_at IS NOT NULL OR NEW.erased_at IS NULL OR
           NEW.erased_at < OLD.accepted_at OR NEW.accepted_by_user_id IS NOT NULL OR
           NEW.evidence_digest IS NOT NULL OR NEW.idempotency_key_digest IS NOT NULL OR
           NEW.request_uuid IS NOT NULL OR
           (NEW.registration_consent_requirement_id, NEW.registration_id, NEW.signer_role,
            NEW.acceptance_method, NEW.content_sha256, NEW.retention_policy_id,
            NEW.retain_until, NEW.accepted_at)
           IS DISTINCT FROM
           (OLD.registration_consent_requirement_id, OLD.registration_id, OLD.signer_role,
            OLD.acceptance_method, OLD.content_sha256, OLD.retention_policy_id,
            OLD.retain_until, OLD.accepted_at) THEN
          RAISE EXCEPTION 'registration consent evidence is immutable except for payload erasure'
            USING ERRCODE = '40001';
        END IF;

        SELECT action INTO retention_action
          FROM core_data_retention_policies
         WHERE id = OLD.retention_policy_id;
        IF retention_action IS DISTINCT FROM 'erase_payload' OR OLD.retain_until IS NULL OR
           OLD.retain_until > clock_timestamp() THEN
          RAISE EXCEPTION 'registration consent evidence cannot be erased before its retention policy permits it'
            USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
          SELECT 1
           FROM core_data_retention_holds hold
           JOIN ticketing_registrations registration ON registration.id = OLD.registration_id
           WHERE hold.released_at IS NULL
              AND hold.starts_at <= clock_timestamp()
              AND (hold.expires_at IS NULL OR hold.expires_at > clock_timestamp())
             AND (hold.category IS NULL OR hold.category = 'consent_evidence')
             AND (hold.registration_id = OLD.registration_id OR
                  hold.event_id = registration.event_id OR
                  hold.user_id = OLD.accepted_by_user_id)
        ) THEN
          RAISE EXCEPTION 'registration consent evidence cannot be erased while a retention hold is active'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER trg_ticketing_registration_consent_locked
        BEFORE UPDATE OR DELETE ON ticketing_registration_consents
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_consent_append_only();

      CREATE OR REPLACE FUNCTION ticketing_registration_consent_integrity()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        requirement_registration_id uuid;
        requirement_scope text;
        requirement_subject_id uuid;
        requirement_status text;
        requirement_version_id uuid;
        version_digest text;
        registration_user_id uuid;
        signer_verified_at timestamptz;
        retention_days integer;
        expected_evidence_digest text;
      BEGIN
        SELECT requirement.registration_id, requirement.acceptance_scope,
               requirement.subject_user_id, requirement.status,
               requirement.consent_document_version_id,
               registration.user_id, signer.verified_at
          INTO requirement_registration_id, requirement_scope, requirement_subject_id,
               requirement_status, requirement_version_id, registration_user_id, signer_verified_at
          FROM ticketing_registration_consent_requirements requirement
          JOIN ticketing_registrations registration ON registration.id = requirement.registration_id
          JOIN core_users signer ON signer.id = NEW.accepted_by_user_id
         WHERE requirement.id = NEW.registration_consent_requirement_id;
        SELECT content_sha256 INTO version_digest
          FROM events_consent_document_versions
         WHERE id = requirement_version_id;

        IF requirement_registration_id IS DISTINCT FROM NEW.registration_id OR
           requirement_status IS DISTINCT FROM 'pending' OR
           version_digest IS DISTINCT FROM NEW.content_sha256 THEN
          RAISE EXCEPTION 'consent evidence must match one pending exact-version requirement'
            USING ERRCODE = '23514';
        END IF;
        IF (requirement_scope = 'buyer' AND
            (NEW.signer_role IS DISTINCT FROM 'buyer' OR
             NEW.accepted_by_user_id IS DISTINCT FROM registration_user_id OR
             requirement_subject_id IS DISTINCT FROM registration_user_id)) OR
           (requirement_scope = 'admission_slot' AND
            (NEW.signer_role IS DISTINCT FROM 'attendee' OR
             requirement_subject_id IS DISTINCT FROM NEW.accepted_by_user_id)) THEN
          RAISE EXCEPTION 'consent evidence signer does not match the requirement subject'
            USING ERRCODE = '23514';
        END IF;
        IF signer_verified_at IS NULL AND NEW.acceptance_method = 'otp' THEN
          RAISE EXCEPTION 'consent evidence signer must have verified OTP identity'
            USING ERRCODE = '23514';
        END IF;
        SELECT policy.retention_days
          INTO retention_days
          FROM core_data_retention_policies policy
         WHERE policy.id = NEW.retention_policy_id
           AND policy.status = 'active'
           AND policy.category = 'consent_evidence'
           AND policy.effective_at <= NEW.accepted_at;
        IF NOT FOUND OR NEW.retain_until IS DISTINCT FROM (
          CASE WHEN retention_days IS NULL THEN NULL
               ELSE NEW.accepted_at + make_interval(days => retention_days)
          END
        ) THEN
          RAISE EXCEPTION 'consent evidence must retain the active effective policy snapshot'
            USING ERRCODE = '23514';
        END IF;
        expected_evidence_digest := encode(digest(
          '{"registration_id":"' || NEW.registration_id::text ||
          '","subject_user_id":"' || requirement_subject_id::text ||
          '","accepted_by_user_id":"' || NEW.accepted_by_user_id::text ||
          '","version_id":"' || requirement_version_id::text ||
          '","content_sha256":"' || NEW.content_sha256 ||
          '","signer_role":"' || NEW.signer_role ||
          '","acceptance_method":"' || NEW.acceptance_method ||
          '","accepted_at":"' || to_char(NEW.accepted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') ||
          '","request_uuid":"' || NEW.request_uuid::text || '"}',
          'sha256'
        ), 'hex');
        IF NEW.evidence_digest IS DISTINCT FROM expected_evidence_digest THEN
          RAISE EXCEPTION 'consent evidence digest must be derived from the exact acceptance event'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER trg_ticketing_registration_consent_integrity
        BEFORE INSERT ON ticketing_registration_consents
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_consent_integrity();

      CREATE OR REPLACE FUNCTION ticketing_registration_consent_requirement_acceptance_evidence()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.status = 'accepted' AND NOT EXISTS (
          SELECT 1
            FROM ticketing_registration_consents consent
           WHERE consent.registration_consent_requirement_id = NEW.id
        ) THEN
          RAISE EXCEPTION 'accepted consent requirements require acceptance evidence'
            USING ERRCODE = '23514';
        END IF;
        RETURN NULL;
      END;
      $$;

      CREATE CONSTRAINT TRIGGER trg_consent_requirement_has_evidence
        AFTER INSERT OR UPDATE OF status ON ticketing_registration_consent_requirements
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_consent_requirement_acceptance_evidence();

      CREATE OR REPLACE FUNCTION ticketing_registration_consent_evidence_requirement_accepted()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
            FROM ticketing_registration_consent_requirements requirement
           WHERE requirement.id = NEW.registration_consent_requirement_id
             AND requirement.status = 'accepted'
        ) THEN
          RAISE EXCEPTION 'consent evidence requires an accepted consent requirement by transaction commit'
            USING ERRCODE = '23514';
        END IF;
        RETURN NULL;
      END;
      $$;

      CREATE CONSTRAINT TRIGGER trg_consent_evidence_requirement_accepted
        AFTER INSERT ON ticketing_registration_consents
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_consent_evidence_requirement_accepted();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_ticketing_registration_consent_integrity
        ON ticketing_registration_consents;
      DROP TRIGGER IF EXISTS trg_consent_evidence_requirement_accepted
        ON ticketing_registration_consents;
      DROP TRIGGER IF EXISTS trg_consent_requirement_has_evidence
        ON ticketing_registration_consent_requirements;
      DROP TRIGGER IF EXISTS trg_ticketing_registration_consent_requirement_acceptance_evidence
        ON ticketing_registration_consent_requirements;
      DROP TRIGGER IF EXISTS trg_ticketing_registration_consent_locked
        ON ticketing_registration_consents;
      DROP FUNCTION IF EXISTS ticketing_registration_consent_integrity();
      DROP FUNCTION IF EXISTS ticketing_registration_consent_evidence_requirement_accepted();
      DROP FUNCTION IF EXISTS ticketing_registration_consent_requirement_acceptance_evidence();
      DROP FUNCTION IF EXISTS ticketing_registration_consent_append_only();
    SQL
    drop_table :ticketing_registration_consents
  end
end
