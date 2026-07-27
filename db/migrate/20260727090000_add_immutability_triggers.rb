# frozen_string_literal: true

# Tamper-evident, DB-level immutability for legal/consent document versions and
# the schedule-change ledger. Application-layer guards (model validations /
# callbacks) already protect these, but they are bypassed by bulk SQL and other
# writers. These triggers enforce the guarantee at the storage layer.
#
#  - Consent & legal document versions: editable while `draft`; once published or
#    retired the substantive columns are frozen (only a forward `status` transition
#    is permitted), and rows can never be deleted.
#  - Event date changes: strictly append-only (INSERT only; UPDATE/DELETE rejected).
class AddImmutabilityTriggers < ActiveRecord::Migration[8.1]
  def up
    # Consent document versions: a draft-only version may be deleted (e.g. when
    # discarding an unpublished document); published/retired versions may not.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION consent_version_delete_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.status = 'draft' THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION 'published or retired consent versions cannot be deleted'
          USING ERRCODE = '40001';
      END;
      $$;
    SQL

    # Legal document versions: same draft-vs-locked delete rule.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION legal_version_delete_guard()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.status = 'draft' THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION 'published or retired legal versions cannot be deleted'
          USING ERRCODE = '40001';
      END;
      $$;
    SQL

    # Consent document versions: freeze substantive columns once not `draft`.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION lock_consent_version_on_update()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.status = 'draft' THEN
          RETURN NEW;
        END IF;
        IF (OLD.body, OLD.content_sha256, OLD.title, OLD.required,
            OLD.acceptance_scope, OLD.consent_document_id, OLD.created_by_id,
            OLD.version, OLD.published_at, OLD.published_by_id)
           IS DISTINCT FROM
           (NEW.body, NEW.content_sha256, NEW.title, NEW.required,
            NEW.acceptance_scope, NEW.consent_document_id, NEW.created_by_id,
            NEW.version, NEW.published_at, NEW.published_by_id) THEN
          RAISE EXCEPTION 'published or retired consent versions are immutable'
            USING ERRCODE = '40001';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL

    # Legal document versions: same rule with their own column set.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION lock_legal_version_on_update()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF OLD.status = 'draft' THEN
          RETURN NEW;
        END IF;
        IF (OLD.body, OLD.commercial_policy_reference, OLD.content_sha256, OLD.title,
            OLD.legal_document_id, OLD.created_by_id, OLD.version,
            OLD.published_at, OLD.published_by_id)
           IS DISTINCT FROM
           (NEW.body, NEW.commercial_policy_reference, NEW.content_sha256, NEW.title,
            NEW.legal_document_id, NEW.created_by_id, NEW.version,
            NEW.published_at, NEW.published_by_id) THEN
          RAISE EXCEPTION 'published or retired legal versions are immutable'
            USING ERRCODE = '40001';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL

    # Event date changes: strictly append-only.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION event_date_change_immutable()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'event date changes are append-only and cannot be modified or deleted'
          USING ERRCODE = '40001';
      END;
      $$;
    SQL

    execute <<~SQL
      DROP TRIGGER IF EXISTS trg_consent_version_locked ON events_consent_document_versions;
      CREATE TRIGGER trg_consent_version_locked
        BEFORE UPDATE ON events_consent_document_versions
        FOR EACH ROW EXECUTE FUNCTION lock_consent_version_on_update();

      DROP TRIGGER IF EXISTS trg_consent_version_nodelete ON events_consent_document_versions;
      CREATE TRIGGER trg_consent_version_nodelete
        BEFORE DELETE ON events_consent_document_versions
        FOR EACH ROW EXECUTE FUNCTION consent_version_delete_guard();

      DROP TRIGGER IF EXISTS trg_legal_version_locked ON legal_document_versions;
      CREATE TRIGGER trg_legal_version_locked
        BEFORE UPDATE ON legal_document_versions
        FOR EACH ROW EXECUTE FUNCTION lock_legal_version_on_update();

      DROP TRIGGER IF EXISTS trg_legal_version_nodelete ON legal_document_versions;
      CREATE TRIGGER trg_legal_version_nodelete
        BEFORE DELETE ON legal_document_versions
        FOR EACH ROW EXECUTE FUNCTION legal_version_delete_guard();

      DROP TRIGGER IF EXISTS trg_event_date_change_immutable ON events_event_date_changes;
      CREATE TRIGGER trg_event_date_change_immutable
        BEFORE UPDATE OR DELETE ON events_event_date_changes
        FOR EACH ROW EXECUTE FUNCTION event_date_change_immutable();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_event_date_change_immutable ON events_event_date_changes;"
    execute "DROP TRIGGER IF EXISTS trg_legal_version_nodelete ON legal_document_versions;"
    execute "DROP TRIGGER IF EXISTS trg_legal_version_locked ON legal_document_versions;"
    execute "DROP TRIGGER IF EXISTS trg_consent_version_nodelete ON events_consent_document_versions;"
    execute "DROP TRIGGER IF EXISTS trg_consent_version_locked ON events_consent_document_versions;"
    execute "DROP FUNCTION IF EXISTS event_date_change_immutable();"
    execute "DROP FUNCTION IF EXISTS lock_legal_version_on_update();"
    execute "DROP FUNCTION IF EXISTS lock_consent_version_on_update();"
    execute "DROP FUNCTION IF EXISTS legal_version_delete_guard();"
    execute "DROP FUNCTION IF EXISTS consent_version_delete_guard();"
  end
end
