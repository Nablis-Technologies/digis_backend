# frozen_string_literal: true

module Ticketing
  module Consent
    # Reassigns one admission coordinate by superseding every current personal
    # requirement and appending a fresh subject-bound requirement per document.
    class SupersedeForReassignment < Core::BaseService
      class Halt < StandardError
        attr_reader :result

        def initialize(result)
          @result = result
          super(result.error.message)
        end
      end

      def initialize(registration:, package_unit_number:, admission_position:, actor:, replacement_subject: nil,
        subject_user: nil, idempotency_key: nil, request_uuid: nil, required_at: Time.current)
        @registration = registration
        @package_unit_number = package_unit_number
        @admission_position = admission_position
        @actor = actor
        @replacement_subject = replacement_subject || subject_user
        @idempotency_key = idempotency_key
        @request_uuid = request_uuid
        @required_at = required_at
      end

      def call
        return failure(error("missing_idempotency_key")) if idempotency_key.blank?

        key_digest = idempotency_digest
        requirements = Registration.transaction do
          locked_registration = Registration.lock.includes(:event).find(registration.id)
          halt("consent_reassignment_forbidden") unless authorized?(locked_registration)
          halt("consent_replacement_required") unless replacement_subject.is_a?(Core::User)

          current = current_requirements(locked_registration)
          halt("consent_requirement_not_found") if current.empty?
          replay = replayed_request(key_digest, locked_registration)
          return success(reassignment_value(current)) if replay
          halt("consent_replacement_subject_conflict") if current.any? do |requirement|
            requirement.subject_user_id == replacement_subject.id
          end

          new_requirements = current.map do |old_requirement|
            old_requirement.update!(status: "superseded", superseded_at: required_at)
            create_replacement!(locked_registration, old_requirement)
          end
          record_audit(locked_registration, new_requirements, key_digest)
          value = reassignment_value(new_requirements)
          publish_credential_requirements!(locked_registration, value, key_digest)
          value
        end

        success(requirements)
      rescue Halt => error
        error.result
      rescue ActiveRecord::RecordInvalid => error_record
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.consents.errors.invalid_requirement"),
            code: "invalid_consent_requirement",
            status: :unprocessable_entity,
            errors: error_record.record.errors.to_hash
          )
        )
      rescue Core::Audit::Record::ReplayConflict
        failure(error("consent_reassignment_conflict"))
      rescue ArgumentError
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.consents.errors.invalid_idempotency_key"),
            code: "invalid_idempotency_key",
            status: :unprocessable_entity
          )
        )
      end

      private

      attr_reader :registration, :package_unit_number, :admission_position, :actor,
                  :replacement_subject, :idempotency_key, :request_uuid, :required_at

      def idempotency_digest
        key = Core::IdempotencyKey.new(idempotency_key)
        Core::KeyedDigest.digest(namespace: "ticketing-consent-reassignment", value: key.to_s)
      end

      def authorized?(locked_registration)
        actor.is_a?(Core::User) &&
          (actor.id == locked_registration.user_id ||
           Events::AuthorizationResolver.can_manage_catalog?(actor, locked_registration.event))
      end

      def current_requirements(locked_registration)
        RegistrationConsentRequirement
          .current
          .where(
            registration_id: locked_registration.id,
            acceptance_scope: "admission_slot",
            package_unit_number:,
            admission_position:
          )
          .lock
          .includes(consent_document_version: :consent_document)
          .order(:id)
          .to_a
      end

      def create_replacement!(locked_registration, old_requirement)
        version = current_version_for(old_requirement.consent_document_version)
        halt("consent_version_not_current") unless version&.acceptance_scope == "admission_slot"

        RegistrationConsentRequirement.create!(
          registration: locked_registration,
          consent_document_version: version,
          required: version.required,
          acceptance_scope: "admission_slot",
          package_unit_number: old_requirement.package_unit_number,
          admission_position: old_requirement.admission_position,
          admission_slot_id: old_requirement.admission_slot_id,
          subject_user: replacement_subject,
          status: "pending",
          supersedes_requirement: old_requirement,
          required_reason: "reconsent",
          required_by: actor,
          required_at:
        )
      end

      def current_version_for(version)
        Events::ConsentDocumentVersion
          .where(consent_document_id: version.consent_document_id, status: "published")
          .lock
          .first
      end

      def reassignment_value(requirements)
        requirements.one? ? requirements.first : requirements
      end

      def replayed_request(key_digest, locked_registration)
        audit = Core::AuditLog.lock.find_by(audit_key: "ticketing-consent-reassignment-#{key_digest}")
        return false unless audit
        return true if audit.metadata.deep_symbolize_keys[:request_digest] == request_digest_for

        halt("consent_reassignment_conflict")
      end

      def request_digest_for
        Core::KeyedDigest.digest(
          namespace: "ticketing-consent-reassignment-request:#{registration.id}",
          value: ActiveSupport::JSON.encode(
            registration_id: registration.id,
            package_unit_number:,
            admission_position:,
            replacement_subject_id: replacement_subject.id,
            actor_id: actor.id,
            request_uuid: request_uuid.presence
          )
        )
      end

      def record_audit(locked_registration, new_requirements, key_digest)
        Core::Audit::Record.call(
          audit_key: "ticketing-consent-reassignment-#{key_digest}",
          action: "ticketing.registration_consent.reassigned",
          auditable_type: "Ticketing::Registration",
          auditable_id: locked_registration.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { admission_position:, package_unit_number: },
          request_uuid: request_uuid.presence,
          metadata: {
            registration_id: locked_registration.id,
            requirement_ids: new_requirements.map(&:id),
            replacement_subject_id: replacement_subject.id,
            idempotency_key_digest: key_digest,
            request_digest: request_digest_for
          }
        ).value
      end

      def publish_credential_requirements!(locked_registration, requirements, key_digest)
        projection = CredentialRequirementStatus.call(registration: locked_registration).value
        Ticketing::Consent::CredentialRequirementsHandoff.call(
          registration: locked_registration,
          status: projection.status,
          affected_coordinates: Array(requirements),
          idempotency_key: "ticketing-consent-reassignment-credential-requirements-#{key_digest}"
        ).value
      end

      def halt(code)
        fail Halt, failure(error(code))
      end

      def error(code)
        Core::BusinessError.new(
          I18n.t("ticketing.consents.errors.#{code}"),
          code:,
          status: :unprocessable_entity
        )
      end
    end
  end
end
