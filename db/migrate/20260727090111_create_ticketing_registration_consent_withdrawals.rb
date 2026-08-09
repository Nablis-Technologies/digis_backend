# frozen_string_literal: true

class CreateTicketingRegistrationConsentWithdrawals < ActiveRecord::Migration[8.1]
  def up
    create_table :ticketing_registration_consent_withdrawals, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :registration_consent_id, null: false
      t.uuid :registration_id, null: false
      t.uuid :withdrawn_by_user_id, null: false
      t.string :reason_code
      t.string :idempotency_key, null: false, limit: 64
      t.timestamptz :withdrawn_at, null: false
      t.timestamps
    end

    add_check_constraint :ticketing_registration_consent_withdrawals,
      "reason_code IS NULL OR reason_code IN ('attendee_request','privacy_request','legal_request','changed_mind')",
      name: "ticketing_consent_withdrawals_reason_check"
    add_check_constraint :ticketing_registration_consent_withdrawals,
      "idempotency_key ~ '^[0-9a-f]{64}$'",
      name: "ticketing_consent_withdrawals_idempotency_digest_check"

    add_index :ticketing_registration_consent_withdrawals, :registration_consent_id,
      unique: true,
      name: "idx_one_withdrawal_per_registration_consent"
    add_index :ticketing_registration_consent_withdrawals, :idempotency_key,
      unique: true,
      name: "idx_unique_consent_withdrawal_idempotency"
    add_index :ticketing_registration_consent_withdrawals, %i[registration_id withdrawn_at],
      name: "idx_consent_withdrawals_by_registration"
    add_index :ticketing_registration_consent_withdrawals, %i[withdrawn_by_user_id withdrawn_at],
      name: "idx_consent_withdrawals_by_signer"

    add_foreign_key :ticketing_registration_consent_withdrawals,
      :ticketing_registration_consents, column: :registration_consent_id, on_delete: :restrict
    add_foreign_key :ticketing_registration_consent_withdrawals,
      :ticketing_registrations, column: :registration_id, on_delete: :restrict
    add_foreign_key :ticketing_registration_consent_withdrawals,
      :core_users, column: :withdrawn_by_user_id, on_delete: :restrict

    execute <<~SQL
      CREATE OR REPLACE FUNCTION ticketing_registration_consent_withdrawal_append_only()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'registration consent withdrawals are immutable and append-only'
          USING ERRCODE = '40001';
      END;
      $$;

      CREATE TRIGGER trg_ticketing_registration_consent_withdrawal_locked
        BEFORE UPDATE OR DELETE ON ticketing_registration_consent_withdrawals
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_consent_withdrawal_append_only();

      CREATE OR REPLACE FUNCTION ticketing_registration_consent_withdrawal_integrity()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        consent_registration_id uuid;
        consent_signer_id uuid;
        requirement_scope text;
        requirement_status text;
      BEGIN
        SELECT consent.registration_id, consent.accepted_by_user_id,
               requirement.acceptance_scope, requirement.status
          INTO consent_registration_id, consent_signer_id,
               requirement_scope, requirement_status
          FROM ticketing_registration_consents consent
          JOIN ticketing_registration_consent_requirements requirement
            ON requirement.id = consent.registration_consent_requirement_id
         WHERE consent.id = NEW.registration_consent_id;
        IF consent_registration_id IS DISTINCT FROM NEW.registration_id OR
           consent_signer_id IS DISTINCT FROM NEW.withdrawn_by_user_id OR
           requirement_scope IS DISTINCT FROM 'admission_slot' OR
           requirement_status IS DISTINCT FROM 'accepted' THEN
          RAISE EXCEPTION 'consent withdrawal must target the original signer''s accepted personal consent'
            USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER trg_ticketing_registration_consent_withdrawal_integrity
        BEFORE INSERT ON ticketing_registration_consent_withdrawals
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_consent_withdrawal_integrity();

      CREATE OR REPLACE FUNCTION ticketing_registration_consent_requirement_withdrawal_evidence()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.status = 'withdrawn' AND NOT EXISTS (
          SELECT 1
            FROM ticketing_registration_consents consent
            JOIN ticketing_registration_consent_withdrawals withdrawal
              ON withdrawal.registration_consent_id = consent.id
           WHERE consent.registration_consent_requirement_id = NEW.id
        ) THEN
          RAISE EXCEPTION 'withdrawn consent requirements require withdrawal evidence'
            USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER trg_ticketing_registration_consent_requirement_withdrawal_evidence
        BEFORE INSERT OR UPDATE OF status ON ticketing_registration_consent_requirements
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_consent_requirement_withdrawal_evidence();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_ticketing_registration_consent_withdrawal_integrity
        ON ticketing_registration_consent_withdrawals;
      DROP TRIGGER IF EXISTS trg_ticketing_registration_consent_requirement_withdrawal_evidence
        ON ticketing_registration_consent_requirements;
      DROP TRIGGER IF EXISTS trg_ticketing_registration_consent_withdrawal_locked
        ON ticketing_registration_consent_withdrawals;
      DROP FUNCTION IF EXISTS ticketing_registration_consent_requirement_withdrawal_evidence();
      DROP FUNCTION IF EXISTS ticketing_registration_consent_withdrawal_integrity();
      DROP FUNCTION IF EXISTS ticketing_registration_consent_withdrawal_append_only();
    SQL
    drop_table :ticketing_registration_consent_withdrawals
  end
end
