# frozen_string_literal: true

module Legal
  class RecordAcceptance < Core::BaseService
    def initialize(subject:, legal_document_version:, accepted_by:,
                   acceptance_method: "checkbox", accepted_by_role: nil,
                   request_uuid: SecureRandom.uuid, accepted_at: Time.current)
      @subject = subject
      @legal_document_version = legal_document_version
      @accepted_by = accepted_by
      @acceptance_method = acceptance_method
      @accepted_by_role = accepted_by_role
      @request_uuid = request_uuid
      @accepted_at = accepted_at
    end

    def call
      Legal::LegalAcceptance.transaction do
        existing = Legal::LegalAcceptance.find_by(request_uuid: request_uuid)
        return success(existing) if existing

        version = legal_document_version
        unless version.published?
          return failure(
            Core::BusinessError.new(
              I18n.t("legal_document.errors.version_not_published"),
              code: "version_not_published", status: :unprocessable_entity
            )
          )
        end

        version_mismatch = commercial_assignment_version_mismatch(version)
        return failure(version_mismatch) if version_mismatch

        lock_subject(subject)

        evidence_digest = LegalDocumentVersion.evidence_digest_for(
          legal_document_version_id: version.id,
          content_sha256: version.content_sha256,
          subject_type: subject_type_for(subject),
          subject_id: subject.id,
          accepted_by_user_id: accepted_by.id,
          accepted_by_role: accepted_by_role,
          acceptance_method: acceptance_method,
          accepted_at: accepted_at,
          request_uuid: request_uuid
        )

        acceptance = Legal::LegalAcceptance.create!(
          subject_type: subject_type_for(subject),
          subject_id: subject.id,
          legal_document_version_id: version.id,
          accepted_by: accepted_by,
          acceptance_method: acceptance_method,
          accepted_by_role: accepted_by_role,
          content_sha256: version.content_sha256,
          evidence_digest: evidence_digest,
          request_uuid: request_uuid,
          accepted_at: accepted_at
        )

        link_commercial_assignment!(acceptance)

        record_audit(acceptance)
        success(acceptance)
      end
    rescue ActiveRecord::RecordInvalid => error
      failure(
        Core::BusinessError.new(
          I18n.t("legal_document.errors.acceptance_invalid"),
          code: "invalid_legal_acceptance",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      )
    rescue ActiveRecord::RecordNotUnique
      existing = Legal::LegalAcceptance.find_by(request_uuid: request_uuid)
      return success(existing) if existing

      # Conflict is on a different unique key (e.g. same subject + version with a
      # different request_uuid), not an idempotent replay — surface the error.
      failure(
        Core::BusinessError.new(
          I18n.t("legal_document.errors.acceptance_conflict"),
          code: "acceptance_conflict",
          status: :unprocessable_entity
        )
      )
    end

    private

    attr_reader :subject, :legal_document_version, :accepted_by,
                :acceptance_method, :accepted_by_role, :request_uuid, :accepted_at

    def subject_type_for(subject)
      case subject
      when Core::User then "user"
      when Organizations::Organization then "organization"
      when Commercial::Assignment then "commercial_assignment"
      when Orders::Order then "order"
      else raise ArgumentError, I18n.t("core.errors.unsupported_subject_type")
      end
    end

    def commercial_assignment_version_mismatch(version)
      return unless subject.is_a?(Commercial::Assignment)

      expected_version_id = subject.fee_schedule_version&.legal_document_version_id
      return if expected_version_id.present? && expected_version_id == version.id

      Core::BusinessError.new(
        I18n.t("legal_document.errors.commercial_version_mismatch"),
        code: "commercial_legal_version_mismatch", status: :unprocessable_entity
      )
    end

    def link_commercial_assignment!(acceptance)
      return unless subject.is_a?(Commercial::Assignment)

      subject.update!(legal_acceptance: acceptance)
    end

    def lock_subject(subject)
      subject.class.lock.find(subject.id)
    end

    def record_audit(acceptance)
      Core::Audit::Record.call(
        audit_key: "legal-accept-#{acceptance.request_uuid}",
        action: "legal.accepted",
        auditable_type: "Legal::LegalAcceptance",
        auditable_id: acceptance.id,
        actor_type: accepted_by.class.name,
        actor_id: accepted_by.id,
        audited_changes: {
          subject_type: acceptance.subject_type,
          subject_id: acceptance.subject_id,
          legal_document_version_id: acceptance.legal_document_version_id
        },
        metadata: { request_uuid: acceptance.request_uuid }
      )
    end
  end
end
