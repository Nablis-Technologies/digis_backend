# frozen_string_literal: true

class AddRegistrationImmutabilityTriggers < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION core_retention_policy_immutable()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.status = 'draft' AND NEW.status = 'active' THEN
          IF NEW.version <= (
            SELECT COALESCE(MAX(version), 0)
              FROM core_data_retention_policies
             WHERE category = NEW.category
               AND jurisdiction_code IS NOT DISTINCT FROM NEW.jurisdiction_code
               AND id <> NEW.id
          ) THEN
            RAISE EXCEPTION 'active retention policy versions must be monotonic'
              USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END IF;

        IF OLD.status = 'draft' THEN
          RETURN NEW;
        END IF;

        IF OLD.status = 'active' AND NEW.status = 'retired' THEN
          IF ROW(OLD.category, OLD.jurisdiction_code, OLD.version, OLD.retention_days,
                 OLD.action, OLD.effective_at, OLD.created_by_id)
             IS DISTINCT FROM
             ROW(NEW.category, NEW.jurisdiction_code, NEW.version, NEW.retention_days,
                 NEW.action, NEW.effective_at, NEW.created_by_id) THEN
            RAISE EXCEPTION 'active retention policies are immutable'
              USING ERRCODE = '40001';
          END IF;
          RETURN NEW;
        END IF;

        IF NEW.status <> OLD.status OR
           ROW(OLD.category, OLD.jurisdiction_code, OLD.version, OLD.retention_days,
               OLD.action, OLD.effective_at, OLD.created_by_id)
           IS DISTINCT FROM
           ROW(NEW.category, NEW.jurisdiction_code, NEW.version, NEW.retention_days,
               NEW.action, NEW.effective_at, NEW.created_by_id) THEN
          RAISE EXCEPTION 'active or retired retention policies are immutable'
            USING ERRCODE = '40001';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION core_retention_policy_active_insert_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.status = 'active' AND NEW.version <= (
          SELECT COALESCE(MAX(version), 0)
            FROM core_data_retention_policies
           WHERE category = NEW.category
             AND jurisdiction_code IS NOT DISTINCT FROM NEW.jurisdiction_code
        ) THEN
          RAISE EXCEPTION 'active retention policy versions must be monotonic'
            USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION core_retention_policy_delete_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.status = 'draft' THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION 'active or retired retention policies cannot be deleted'
          USING ERRCODE = '40001';
      END;
      $$;

      CREATE OR REPLACE FUNCTION registration_form_version_immutable()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.status = 'draft' THEN
          RETURN NEW;
        END IF;

        IF OLD.status = 'published' AND NEW.status = 'retired' THEN
          IF ROW(OLD.registration_form_id, OLD.version, OLD.published_by_id, OLD.published_at)
             IS DISTINCT FROM
             ROW(NEW.registration_form_id, NEW.version, NEW.published_by_id, NEW.published_at) THEN
            RAISE EXCEPTION 'published registration form versions are immutable'
              USING ERRCODE = '40001';
          END IF;
          RETURN NEW;
        END IF;

        IF NEW.status <> OLD.status OR
           ROW(OLD.registration_form_id, OLD.version, OLD.published_by_id, OLD.published_at)
           IS DISTINCT FROM
           ROW(NEW.registration_form_id, NEW.version, NEW.published_by_id, NEW.published_at) THEN
          RAISE EXCEPTION 'published or retired registration form versions are immutable'
            USING ERRCODE = '40001';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION registration_form_version_delete_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.status = 'draft' THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION 'published or retired registration form versions cannot be deleted'
          USING ERRCODE = '40001';
      END;
      $$;

      CREATE OR REPLACE FUNCTION registration_question_immutable()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        version_status text;
        new_version_status text;
      BEGIN
        SELECT status INTO version_status
          FROM ticketing_registration_form_versions
          WHERE id = OLD.registration_form_version_id
          FOR UPDATE;
        SELECT status INTO new_version_status
          FROM ticketing_registration_form_versions
          WHERE id = NEW.registration_form_version_id
          FOR UPDATE;
        IF COALESCE(version_status, '') <> 'draft' THEN
          RAISE EXCEPTION 'questions in published or retired versions are immutable'
            USING ERRCODE = '40001';
        END IF;
        IF COALESCE(new_version_status, '') <> 'draft' THEN
          RAISE EXCEPTION 'questions cannot move into published or retired versions'
            USING ERRCODE = '40001';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION registration_question_delete_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        version_status text;
      BEGIN
        SELECT status INTO version_status
          FROM ticketing_registration_form_versions
          WHERE id = OLD.registration_form_version_id
          FOR UPDATE;
        IF version_status = 'draft' THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION 'questions in published or retired versions cannot be deleted'
          USING ERRCODE = '40001';
      END;
      $$;

      CREATE OR REPLACE FUNCTION registration_question_insert_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        version_status text;
      BEGIN
        SELECT status INTO version_status
          FROM ticketing_registration_form_versions
          WHERE id = NEW.registration_form_version_id
          FOR UPDATE;
        IF version_status = 'draft' THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'questions cannot be added to published or retired versions'
          USING ERRCODE = '40001';
      END;
      $$;

      CREATE OR REPLACE FUNCTION registration_answer_append_only()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.erased_at IS NOT NULL THEN
          IF ROW(OLD.registration_form_submission_id, OLD.registration_question_id,
                 OLD.question_key_snapshot, OLD.question_type_snapshot,
                 OLD.response_scope_snapshot, OLD.question_label_snapshot,
                 OLD.package_unit_number, OLD.admission_position, OLD.admission_slot_id,
                 OLD.answer_ciphertext, OLD.retention_policy_id, OLD.retain_until,
                 OLD.answered_at, OLD.erased_at, OLD.erasure_reason)
             IS DISTINCT FROM
             ROW(NEW.registration_form_submission_id, NEW.registration_question_id,
                 NEW.question_key_snapshot, NEW.question_type_snapshot,
                 NEW.response_scope_snapshot, NEW.question_label_snapshot,
                 NEW.package_unit_number, NEW.admission_position, NEW.admission_slot_id,
                 NEW.answer_ciphertext, NEW.retention_policy_id, NEW.retain_until,
                 NEW.answered_at, NEW.erased_at, NEW.erasure_reason) THEN
            RAISE EXCEPTION 'erased registration answers are immutable'
              USING ERRCODE = '40001';
          END IF;
          RETURN NEW;
        END IF;

        IF NEW.erased_at IS NULL AND NEW.erasure_reason IS NULL AND
           NEW.answer_ciphertext IS NOT DISTINCT FROM OLD.answer_ciphertext AND
           (OLD.admission_slot_id IS NULL OR
            NEW.admission_slot_id IS NOT DISTINCT FROM OLD.admission_slot_id) AND
           ROW(OLD.registration_form_submission_id, OLD.registration_question_id,
               OLD.question_key_snapshot, OLD.question_type_snapshot,
               OLD.response_scope_snapshot, OLD.question_label_snapshot,
               OLD.package_unit_number, OLD.admission_position, OLD.retention_policy_id,
               OLD.retain_until, OLD.answered_at, OLD.erased_at, OLD.erasure_reason)
           IS NOT DISTINCT FROM
           ROW(NEW.registration_form_submission_id, NEW.registration_question_id,
               NEW.question_key_snapshot, NEW.question_type_snapshot,
               NEW.response_scope_snapshot, NEW.question_label_snapshot,
               NEW.package_unit_number, NEW.admission_position, NEW.retention_policy_id,
               NEW.retain_until, NEW.answered_at, NEW.erased_at, NEW.erasure_reason) THEN
          RETURN NEW;
        END IF;

        IF NEW.erased_at IS NOT NULL AND NEW.erasure_reason IS NOT NULL AND
           NEW.answer_ciphertext IS NULL AND
           (OLD.admission_slot_id IS NULL OR
            NEW.admission_slot_id IS NOT DISTINCT FROM OLD.admission_slot_id) AND
           ROW(OLD.registration_form_submission_id, OLD.registration_question_id,
               OLD.question_key_snapshot, OLD.question_type_snapshot,
               OLD.response_scope_snapshot, OLD.question_label_snapshot,
               OLD.package_unit_number, OLD.admission_position, OLD.retention_policy_id,
               OLD.retain_until, OLD.answered_at)
           IS NOT DISTINCT FROM
           ROW(NEW.registration_form_submission_id, NEW.registration_question_id,
               NEW.question_key_snapshot, NEW.question_type_snapshot,
               NEW.response_scope_snapshot, NEW.question_label_snapshot,
               NEW.package_unit_number, NEW.admission_position, NEW.retention_policy_id,
               NEW.retain_until, NEW.answered_at) THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'registration answers are append-only except issuance and erasure'
          USING ERRCODE = '40001';
      END;
      $$;

      CREATE OR REPLACE FUNCTION registration_answer_delete_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'registration answers cannot be deleted'
          USING ERRCODE = '40001';
      END;
      $$;

      CREATE OR REPLACE FUNCTION registration_source_immutable()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.submitted_at IS NOT NULL AND NEW.source IS DISTINCT FROM OLD.source THEN
          RAISE EXCEPTION 'registration source is immutable after submission'
            USING ERRCODE = '40001';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION registration_answer_revision_append_only()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.erased_at IS NOT NULL THEN
           IF ROW(OLD.registration_answer_id, OLD.revision_number, OLD.answer_ciphertext,
                  OLD.revised_by_id, OLD.source, OLD.reason_code, OLD.idempotency_key_digest,
                  OLD.request_digest, OLD.revised_at, OLD.retain_until, OLD.erased_at)
              IS DISTINCT FROM
              ROW(NEW.registration_answer_id, NEW.revision_number, NEW.answer_ciphertext,
                  NEW.revised_by_id, NEW.source, NEW.reason_code, NEW.idempotency_key_digest,
                  NEW.request_digest, NEW.revised_at, NEW.retain_until, NEW.erased_at) THEN
            RAISE EXCEPTION 'erased answer revisions are immutable'
              USING ERRCODE = '40001';
          END IF;
          RETURN NEW;
        END IF;

        IF NEW.erased_at IS NULL AND NEW.answer_ciphertext IS NOT DISTINCT FROM OLD.answer_ciphertext AND
           ROW(OLD.registration_answer_id, OLD.revision_number, OLD.revised_by_id,
                OLD.source, OLD.reason_code, OLD.idempotency_key_digest, OLD.request_digest,
                OLD.revised_at, OLD.retain_until, OLD.erased_at)
            IS NOT DISTINCT FROM
            ROW(NEW.registration_answer_id, NEW.revision_number, NEW.revised_by_id,
                NEW.source, NEW.reason_code, NEW.idempotency_key_digest, NEW.request_digest,
                NEW.revised_at, NEW.retain_until, NEW.erased_at) THEN
          RETURN NEW;
        END IF;

        IF NEW.erased_at IS NOT NULL AND NEW.answer_ciphertext IS NULL AND
           ROW(OLD.registration_answer_id, OLD.revision_number, OLD.revised_by_id,
                OLD.source, OLD.reason_code, OLD.idempotency_key_digest, OLD.request_digest,
                OLD.revised_at, OLD.retain_until)
            IS NOT DISTINCT FROM
            ROW(NEW.registration_answer_id, NEW.revision_number, NEW.revised_by_id,
                NEW.source, NEW.reason_code, NEW.idempotency_key_digest, NEW.request_digest,
                NEW.revised_at, NEW.retain_until) THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'answer revisions are append-only except erasure'
          USING ERRCODE = '40001';
      END;
      $$;

      CREATE OR REPLACE FUNCTION registration_answer_revision_delete_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'answer revisions cannot be deleted'
          USING ERRCODE = '40001';
      END;
      $$;

      CREATE OR REPLACE FUNCTION registration_answer_revision_sequence()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        expected_revision integer;
      BEGIN
        SELECT COALESCE(MAX(revision_number), 0) + 1
          INTO expected_revision
          FROM ticketing_registration_answer_revisions
          WHERE registration_answer_id = NEW.registration_answer_id;
        IF NEW.revision_number <> expected_revision THEN
          RAISE EXCEPTION 'answer revisions must be appended in order'
            USING ERRCODE = '40001';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION ticketing_registration_same_event_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        ticket_event_id uuid;
        related_event_id uuid;
      BEGIN
        IF TG_OP = 'UPDATE' AND
           (NEW.event_id IS DISTINCT FROM OLD.event_id OR
            NEW.ticket_type_id IS DISTINCT FROM OLD.ticket_type_id OR
            NEW.selected_event_date_id IS DISTINCT FROM OLD.selected_event_date_id OR
            NEW.package_quantity IS DISTINCT FROM OLD.package_quantity OR
            NEW.admissions_per_unit_snapshot IS DISTINCT FROM OLD.admissions_per_unit_snapshot OR
            NEW.party_size IS DISTINCT FROM OLD.party_size) AND
           EXISTS (
             SELECT 1
               FROM ticketing_registration_form_submissions
              WHERE registration_id = OLD.id
           ) THEN
           RAISE EXCEPTION 'registration scopes and snapshots are immutable after form submission'
             USING ERRCODE = '23514';
        END IF;

        SELECT event_product.event_id INTO ticket_event_id
          FROM ticketing_ticket_types ticket_type
          JOIN catalog_event_products event_product ON event_product.id = ticket_type.event_product_id
          WHERE ticket_type.id = NEW.ticket_type_id;
        IF ticket_event_id IS DISTINCT FROM NEW.event_id THEN
          RAISE EXCEPTION 'registrations must reference a ticket type from the same event'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.selected_event_date_id IS NOT NULL THEN
          SELECT event_id INTO related_event_id
            FROM events_event_dates
            WHERE id = NEW.selected_event_date_id;
          IF related_event_id IS DISTINCT FROM NEW.event_id THEN
            RAISE EXCEPTION 'registrations must reference an event date from the same event'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.access_code_id IS NOT NULL THEN
          SELECT event_product.event_id INTO related_event_id
            FROM ticketing_access_codes access_code
            JOIN ticketing_ticket_types ticket_type ON ticket_type.id = access_code.ticket_type_id
            JOIN catalog_event_products event_product ON event_product.id = ticket_type.event_product_id
            WHERE access_code.id = NEW.access_code_id;
          IF related_event_id IS DISTINCT FROM NEW.event_id THEN
            RAISE EXCEPTION 'registrations must reference an access code from the same event'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        IF NEW.invitation_id IS NOT NULL THEN
          SELECT event_product.event_id INTO related_event_id
            FROM ticketing_invitations invitation
            JOIN ticketing_ticket_types ticket_type ON ticket_type.id = invitation.ticket_type_id
            JOIN catalog_event_products event_product ON event_product.id = ticket_type.event_product_id
            WHERE invitation.id = NEW.invitation_id;
          IF related_event_id IS DISTINCT FROM NEW.event_id THEN
            RAISE EXCEPTION 'registrations must reference an invitation from the same event'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION ticketing_registration_submission_immutable()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'registration form submissions are immutable'
          USING ERRCODE = '40001';
      END;
      $$;

      CREATE OR REPLACE FUNCTION ticketing_registration_form_scope_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        ticket_event_id uuid;
      BEGIN
        IF TG_OP = 'UPDATE' AND
           (NEW.event_id IS DISTINCT FROM OLD.event_id OR
            NEW.ticket_type_id IS DISTINCT FROM OLD.ticket_type_id) AND
           EXISTS (
             SELECT 1
               FROM ticketing_registration_form_versions
              WHERE registration_form_id = OLD.id
                AND status <> 'draft'
           ) THEN
          RAISE EXCEPTION 'published registration form scopes are immutable'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.ticket_type_id IS NOT NULL THEN
          SELECT event_product.event_id INTO ticket_event_id
            FROM ticketing_ticket_types ticket_type
            JOIN catalog_event_products event_product ON event_product.id = ticket_type.event_product_id
            WHERE ticket_type.id = NEW.ticket_type_id;
          IF ticket_event_id IS DISTINCT FROM NEW.event_id THEN
            RAISE EXCEPTION 'registration forms must reference a ticket type from the same event'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION ticketing_registration_submission_scope_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        registration_event_id uuid;
        registration_ticket_type_id uuid;
        form_event_id uuid;
        form_ticket_type_id uuid;
      BEGIN
        SELECT registration.event_id, registration.ticket_type_id,
               form.event_id, form.ticket_type_id
          INTO registration_event_id, registration_ticket_type_id,
               form_event_id, form_ticket_type_id
          FROM ticketing_registrations registration
          JOIN ticketing_registration_form_versions version
            ON version.id = NEW.registration_form_version_id
          JOIN ticketing_registration_forms form
            ON form.id = version.registration_form_id
         WHERE registration.id = NEW.registration_id;

        IF registration_event_id IS DISTINCT FROM form_event_id OR
           (form_ticket_type_id IS NOT NULL AND
            form_ticket_type_id IS DISTINCT FROM registration_ticket_type_id) THEN
          RAISE EXCEPTION 'registration submissions must reference a form from the same event and product scope'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION ticketing_registration_answer_revision_retention_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        answer_retain_until timestamptz;
      BEGIN
        SELECT retain_until INTO answer_retain_until
          FROM ticketing_registration_answers
         WHERE id = NEW.registration_answer_id;
        IF NEW.retain_until IS DISTINCT FROM answer_retain_until THEN
          RAISE EXCEPTION 'answer revisions must inherit the original retention deadline'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION ticketing_registration_answer_integrity_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        question_version_id uuid;
        question_key text;
        question_type text;
        question_scope text;
        question_label text;
        submission_version_id uuid;
        package_quantity integer;
        admissions_per_unit integer;
        retention_days integer;
        policy_category text;
        policy_action text;
        policy_status text;
        policy_effective_at timestamptz;
      BEGIN
        SELECT question.registration_form_version_id, question.key, question.type,
               question.response_scope, question.label,
               submission.registration_form_version_id,
               registration.package_quantity, registration.admissions_per_unit_snapshot
          INTO question_version_id, question_key, question_type, question_scope, question_label,
               submission_version_id, package_quantity, admissions_per_unit
          FROM ticketing_registration_questions question
          JOIN ticketing_registration_form_submissions submission
            ON submission.id = NEW.registration_form_submission_id
          JOIN ticketing_registrations registration
            ON registration.id = submission.registration_id
         WHERE question.id = NEW.registration_question_id;

        IF question_version_id IS NULL OR question_version_id IS DISTINCT FROM submission_version_id OR
           NEW.question_key_snapshot IS DISTINCT FROM question_key OR
           NEW.question_type_snapshot IS DISTINCT FROM question_type OR
           NEW.response_scope_snapshot IS DISTINCT FROM question_scope OR
           NEW.question_label_snapshot IS DISTINCT FROM question_label THEN
          RAISE EXCEPTION 'registration answers must match their submission question and version'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.response_scope_snapshot = 'registration' THEN
          IF NEW.package_unit_number IS NOT NULL OR NEW.admission_position IS NOT NULL OR
             NEW.admission_slot_id IS NOT NULL THEN
            RAISE EXCEPTION 'registration-scoped answers cannot have admission coordinates'
              USING ERRCODE = '23514';
          END IF;
        ELSIF NEW.response_scope_snapshot = 'admission_slot' THEN
          IF NEW.package_unit_number IS NULL OR NEW.package_unit_number <= 0 OR
             NEW.package_unit_number > package_quantity OR
             NEW.admission_position IS NULL OR NEW.admission_position <= 0 OR
             NEW.admission_position > admissions_per_unit THEN
            RAISE EXCEPTION 'admission-slot answer coordinates are outside the registration bounds'
              USING ERRCODE = '23514';
          END IF;
        ELSE
          RAISE EXCEPTION 'registration answer response scope is invalid'
            USING ERRCODE = '23514';
        END IF;

        SELECT policy.retention_days, policy.category, policy.action, policy.status, policy.effective_at
          INTO retention_days, policy_category, policy_action, policy_status, policy_effective_at
          FROM core_data_retention_policies policy
         WHERE policy.id = NEW.retention_policy_id;
        IF policy_status IS NULL OR
           (policy_status NOT IN ('active', 'retired') OR
            (policy_status = 'retired' AND NOT (
              TG_OP = 'UPDATE' AND OLD.erased_at IS NULL AND NEW.erased_at IS NOT NULL AND
              NEW.answer_ciphertext IS NULL AND policy_action = 'erase_payload'
            ))) OR
           policy_effective_at IS NULL OR policy_effective_at > NEW.answered_at OR
           policy_category IS DISTINCT FROM (CASE
             WHEN question_type IN ('short_text', 'long_text') THEN 'registration_free_text'
             ELSE 'registration_structured'
           END) THEN
          RAISE EXCEPTION 'registration answers must use an active matching retention policy'
            USING ERRCODE = '23514';
        END IF;
        IF retention_days IS NULL AND NEW.retain_until IS NOT NULL THEN
          RAISE EXCEPTION 'answers with indefinite retention cannot have a deadline'
            USING ERRCODE = '23514';
        ELSIF retention_days IS NOT NULL AND
              NEW.retain_until IS DISTINCT FROM NEW.answered_at + retention_days * interval '1 day' THEN
          RAISE EXCEPTION 'registration answer retention deadlines must match the policy'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE TRIGGER trg_core_retention_policy_active_insert
        BEFORE INSERT ON core_data_retention_policies
        FOR EACH ROW EXECUTE FUNCTION core_retention_policy_active_insert_guard();
      CREATE TRIGGER trg_core_retention_policy_locked
        BEFORE UPDATE ON core_data_retention_policies
        FOR EACH ROW EXECUTE FUNCTION core_retention_policy_immutable();
      CREATE TRIGGER trg_core_retention_policy_nodelete
        BEFORE DELETE ON core_data_retention_policies
        FOR EACH ROW EXECUTE FUNCTION core_retention_policy_delete_guard();
      CREATE TRIGGER trg_registration_form_version_locked
        BEFORE UPDATE ON ticketing_registration_form_versions
        FOR EACH ROW EXECUTE FUNCTION registration_form_version_immutable();
      CREATE TRIGGER trg_registration_form_version_nodelete
        BEFORE DELETE ON ticketing_registration_form_versions
        FOR EACH ROW EXECUTE FUNCTION registration_form_version_delete_guard();
      CREATE TRIGGER trg_registration_question_locked
        BEFORE UPDATE ON ticketing_registration_questions
        FOR EACH ROW EXECUTE FUNCTION registration_question_immutable();
      CREATE TRIGGER trg_registration_question_insert
        BEFORE INSERT ON ticketing_registration_questions
        FOR EACH ROW EXECUTE FUNCTION registration_question_insert_guard();
      CREATE TRIGGER trg_registration_question_nodelete
        BEFORE DELETE ON ticketing_registration_questions
        FOR EACH ROW EXECUTE FUNCTION registration_question_delete_guard();
      CREATE TRIGGER trg_registration_source_locked
        BEFORE UPDATE ON ticketing_registrations
        FOR EACH ROW EXECUTE FUNCTION registration_source_immutable();
      CREATE TRIGGER trg_registration_answer_append_only
        BEFORE UPDATE ON ticketing_registration_answers
        FOR EACH ROW EXECUTE FUNCTION registration_answer_append_only();
      CREATE TRIGGER trg_registration_answer_nodelete
        BEFORE DELETE ON ticketing_registration_answers
        FOR EACH ROW EXECUTE FUNCTION registration_answer_delete_guard();
      CREATE TRIGGER trg_registration_answer_revision_append_only
        BEFORE UPDATE ON ticketing_registration_answer_revisions
        FOR EACH ROW EXECUTE FUNCTION registration_answer_revision_append_only();
      CREATE TRIGGER trg_registration_answer_revision_nodelete
        BEFORE DELETE ON ticketing_registration_answer_revisions
        FOR EACH ROW EXECUTE FUNCTION registration_answer_revision_delete_guard();
      CREATE TRIGGER trg_registration_answer_revision_sequence
        BEFORE INSERT ON ticketing_registration_answer_revisions
        FOR EACH ROW EXECUTE FUNCTION registration_answer_revision_sequence();
      CREATE TRIGGER trg_ticketing_registration_same_event
        BEFORE INSERT OR UPDATE ON ticketing_registrations
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_same_event_guard();
      CREATE TRIGGER trg_ticketing_registration_submission_immutable
        BEFORE UPDATE OR DELETE ON ticketing_registration_form_submissions
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_submission_immutable();
      CREATE TRIGGER trg_ticketing_registration_form_scope
        BEFORE INSERT OR UPDATE ON ticketing_registration_forms
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_form_scope_guard();
      CREATE TRIGGER trg_ticketing_registration_submission_scope
        BEFORE INSERT OR UPDATE ON ticketing_registration_form_submissions
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_submission_scope_guard();
      CREATE TRIGGER trg_ticketing_registration_answer_revision_retention
        BEFORE INSERT OR UPDATE ON ticketing_registration_answer_revisions
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_answer_revision_retention_guard();
      CREATE TRIGGER trg_ticketing_registration_answer_integrity
        BEFORE INSERT OR UPDATE ON ticketing_registration_answers
        FOR EACH ROW EXECUTE FUNCTION ticketing_registration_answer_integrity_guard();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_core_retention_policy_active_insert ON core_data_retention_policies;
      DROP TRIGGER IF EXISTS trg_registration_answer_revision_nodelete ON ticketing_registration_answer_revisions;
      DROP TRIGGER IF EXISTS trg_ticketing_registration_answer_revision_retention ON ticketing_registration_answer_revisions;
      DROP TRIGGER IF EXISTS trg_ticketing_registration_answer_integrity ON ticketing_registration_answers;
      DROP TRIGGER IF EXISTS trg_ticketing_registration_submission_immutable ON ticketing_registration_form_submissions;
      DROP TRIGGER IF EXISTS trg_ticketing_registration_submission_scope ON ticketing_registration_form_submissions;
      DROP TRIGGER IF EXISTS trg_ticketing_registration_form_scope ON ticketing_registration_forms;
      DROP TRIGGER IF EXISTS trg_ticketing_registration_same_event ON ticketing_registrations;
      DROP TRIGGER IF EXISTS trg_registration_answer_revision_sequence ON ticketing_registration_answer_revisions;
      DROP TRIGGER IF EXISTS trg_registration_answer_revision_append_only ON ticketing_registration_answer_revisions;
      DROP TRIGGER IF EXISTS trg_registration_answer_nodelete ON ticketing_registration_answers;
      DROP TRIGGER IF EXISTS trg_registration_answer_append_only ON ticketing_registration_answers;
      DROP TRIGGER IF EXISTS trg_registration_question_nodelete ON ticketing_registration_questions;
      DROP TRIGGER IF EXISTS trg_registration_question_insert ON ticketing_registration_questions;
      DROP TRIGGER IF EXISTS trg_registration_question_locked ON ticketing_registration_questions;
      DROP TRIGGER IF EXISTS trg_registration_source_locked ON ticketing_registrations;
      DROP TRIGGER IF EXISTS trg_registration_form_version_nodelete ON ticketing_registration_form_versions;
      DROP TRIGGER IF EXISTS trg_registration_form_version_locked ON ticketing_registration_form_versions;
      DROP TRIGGER IF EXISTS trg_core_retention_policy_nodelete ON core_data_retention_policies;
      DROP TRIGGER IF EXISTS trg_core_retention_policy_locked ON core_data_retention_policies;
      DROP FUNCTION IF EXISTS registration_answer_revision_delete_guard();
      DROP FUNCTION IF EXISTS ticketing_registration_answer_revision_retention_guard();
      DROP FUNCTION IF EXISTS ticketing_registration_answer_integrity_guard();
      DROP FUNCTION IF EXISTS core_retention_policy_active_insert_guard();
      DROP FUNCTION IF EXISTS ticketing_registration_submission_immutable();
      DROP FUNCTION IF EXISTS ticketing_registration_submission_scope_guard();
      DROP FUNCTION IF EXISTS ticketing_registration_form_scope_guard();
      DROP FUNCTION IF EXISTS ticketing_registration_same_event_guard();
      DROP FUNCTION IF EXISTS registration_answer_revision_sequence();
      DROP FUNCTION IF EXISTS registration_answer_revision_append_only();
      DROP FUNCTION IF EXISTS registration_answer_delete_guard();
      DROP FUNCTION IF EXISTS registration_answer_append_only();
      DROP FUNCTION IF EXISTS registration_question_delete_guard();
      DROP FUNCTION IF EXISTS registration_question_insert_guard();
      DROP FUNCTION IF EXISTS registration_question_immutable();
      DROP FUNCTION IF EXISTS registration_source_immutable();
      DROP FUNCTION IF EXISTS registration_form_version_delete_guard();
      DROP FUNCTION IF EXISTS registration_form_version_immutable();
      DROP FUNCTION IF EXISTS core_retention_policy_delete_guard();
      DROP FUNCTION IF EXISTS core_retention_policy_immutable();
    SQL
  end
end
