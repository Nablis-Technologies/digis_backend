# frozen_string_literal: true

module Ticketing
  module Consent
    # Withdraws one acceptance by its original verified signer. Required
    # personal consent gets a new pending lineage row; buyer contracts never do.
    class Withdraw < Core::BaseService
      class Halt < StandardError
        attr_reader :result

        def initialize(result)
          @result = result
          super(result.error.message)
        end
      end

      def initialize(consent:, actor:, idempotency_key:, reason_code: nil, withdrawn_at: Time.current)
        @consent = consent
        @actor = actor
        @idempotency_key = idempotency_key
        @reason_code = reason_code
        @withdrawn_at = withdrawn_at
      end

      def call
        digest = Core::IdempotencyKey.new(idempotency_key).digest
        projection = Registration.transaction do
          acceptance = RegistrationConsent.lock.includes(:registration).find(consent.id)
          halt("consent_withdrawal_subject_mismatch") unless original_signer?(acceptance)
          existing = RegistrationConsentWithdrawal.lock.find_by(idempotency_key: digest)
          break replay_or_conflict(existing, acceptance, digest) if existing

          existing = RegistrationConsentWithdrawal.lock.find_by(registration_consent_id: acceptance.id)
          if existing
            break replay_or_conflict(existing, acceptance, digest)
          end

          requirement = RegistrationConsentRequirement.lock.find(acceptance.registration_consent_requirement_id)
          halt("buyer_consent_withdrawal_forbidden") if requirement.acceptance_scope == "buyer"
          halt("consent_requirement_not_accepted") unless requirement.accepted?

          withdrawal = RegistrationConsentWithdrawal.create!(
            registration_consent: acceptance,
            registration: acceptance.registration,
            withdrawn_by_user: actor,
            reason_code:,
            idempotency_key: digest,
            withdrawn_at:
          )
          acceptance.association(:withdrawal).target = withdrawal
          requirement.association(:registration_consent).target = acceptance
          requirement.update!(status: "withdrawn")
          append_reacceptance!(acceptance.registration, requirement) if requirement.required?
          record_audit(withdrawal, requirement)
          projection = CredentialRequirementStatus.call(registration: acceptance.registration).value
          publish_credential_requirements!(acceptance.registration, projection, requirement, withdrawal)
          projection
        end

        success(projection)
      rescue Halt => error
        error.result
      rescue ActiveRecord::RecordInvalid => error_record
        if error_record.record.is_a?(RegistrationConsentWithdrawal) &&
           error_record.record.errors.details[:idempotency_key]&.any? { |detail| detail[:error] == :taken }
          return failure(error("consent_withdrawal_conflict"))
        end

        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.consents.errors.invalid_withdrawal"),
            code: "invalid_consent_withdrawal",
            status: :unprocessable_entity,
            errors: error_record.record.errors.to_hash
          )
        )
      rescue ActiveRecord::RecordNotUnique
        existing = RegistrationConsentWithdrawal.find_by(idempotency_key: digest)
        acceptance = RegistrationConsent.find(consent.id)
        if existing && replay_matches?(existing, acceptance, digest)
          return success(CredentialRequirementStatus.call(registration: acceptance.registration).value)
        end

        failure(error("consent_withdrawal_conflict"))
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

      attr_reader :consent, :actor, :idempotency_key, :reason_code, :withdrawn_at

      def original_signer?(acceptance)
        actor.is_a?(Core::User) && actor.verified_at.present? &&
          acceptance.accepted_by_user_id == actor.id
      end

      def replay_or_conflict(existing, acceptance, digest)
        if replay_matches?(existing, acceptance, digest)
          return CredentialRequirementStatus.call(registration: acceptance.registration).value
        end

        halt("consent_withdrawal_conflict")
      end

      def replay_matches?(existing, acceptance, digest)
        existing.idempotency_key == digest &&
          existing.registration_consent_id == acceptance.id &&
          existing.withdrawn_by_user_id == actor.id &&
          existing.reason_code == reason_code
      end

      def append_reacceptance!(registration, requirement)
        version = Events::ConsentDocumentVersion
          .where(consent_document_id: requirement.consent_document_version.consent_document_id, status: "published")
          .lock
          .first
        halt("consent_version_not_current") unless version&.acceptance_scope == "admission_slot"

        RegistrationConsentRequirement.create!(
          registration:,
          consent_document_version: version,
          required: version.required,
          acceptance_scope: version.acceptance_scope,
          package_unit_number: requirement.package_unit_number,
          admission_position: requirement.admission_position,
          admission_slot_id: requirement.admission_slot_id,
          subject_user: requirement.subject_user,
          status: "pending",
          supersedes_requirement: requirement,
          required_reason: "reconsent",
          required_by: actor,
          required_at: withdrawn_at
        )
      end

      def record_audit(withdrawal, requirement)
        Core::Audit::Record.call(
          audit_key: "ticketing-consent-withdrawal-#{withdrawal.idempotency_key}",
          action: "ticketing.registration_consent.withdrawn",
          auditable_type: withdrawal.class.name,
          auditable_id: withdrawal.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { status: [ "accepted", "withdrawn" ] },
          metadata: {
            registration_id: requirement.registration_id,
            requirement_id: requirement.id,
            acceptance_scope: requirement.acceptance_scope
          }
        ).value
      end

      def publish_credential_requirements!(registration, projection, requirement, withdrawal)
        Ticketing::Consent::CredentialRequirementsHandoff.call(
          registration:,
          status: projection.status,
          affected_coordinates: [ requirement ],
          idempotency_key: "ticketing-consent-withdrawal-credential-requirements-#{withdrawal.idempotency_key}"
        ).value
      end

      def halt(code)
        fail Halt, failure(
          Core::BusinessError.new(
            I18n.t("ticketing.consents.errors.#{code}"),
            code:,
            status: :unprocessable_entity
          )
        )
      end
    end
  end
end
