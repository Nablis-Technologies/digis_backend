# frozen_string_literal: true

module Ticketing
  module Consent
    # Accepts one exact requirement snapshot after OTP-authenticated subject
    # checks. The evidence row and requirement transition commit together and
    # are never replaced by a later version or replay.
    class Accept < Core::BaseService
      def initialize(requirement:, actor:, request_uuid:, acceptance_method: "otp", content_sha256: nil,
        idempotency_key: nil, accepted_at: Time.current, requirement_locked: false,
        idempotency_lookup: :unchecked, allow_unverified: false)
        @requirement = requirement
        @actor = actor
        @request_uuid = request_uuid
        @acceptance_method = acceptance_method
        @content_sha256 = content_sha256
        @idempotency_key = idempotency_key
        @accepted_at = accepted_at
        @requirement_locked = requirement_locked
        @idempotency_lookup = idempotency_lookup
        @allow_unverified = allow_unverified
      end

      def call
        return failure(error("missing_idempotency_key")) if idempotency_key.blank?
        return failure(error("consent_subject_unverified")) unless actor.is_a?(Core::User) && (@allow_unverified || actor.verified_at.present?)
        return failure(error("invalid_request_uuid")) unless valid_request_uuid?

        key_digest = idempotency_key_digest
        RegistrationConsent.transaction do
          locked_requirement = self.locked_requirement
          existing = preloaded_idempotency_acceptance(key_digest)
          return replay_or_conflict(existing, locked_requirement, key_digest) if existing

          existing = locked_requirement.registration_consent
          if existing
            return replay_or_conflict(existing, locked_requirement, key_digest)
          end

          return failure(error("consent_requirement_not_pending")) unless locked_requirement.pending?

          version = locked_requirement.consent_document_version
           return failure(error("consent_version_not_current")) unless acceptable_version?(version)
          return failure(error("consent_content_mismatch")) if content_sha256.present? && content_sha256 != version.content_sha256

          signer_role, signer_error = signer_role_for(locked_requirement)
          return failure(error(signer_error)) if signer_error

          policy_result = Core::Retention::SelectPolicy.call(
            category: "consent_evidence",
            at: accepted_at
          )
          return policy_result if policy_result.failure?

          acceptance = RegistrationConsent.create!(
            registration_consent_requirement: locked_requirement,
            registration: locked_requirement.registration,
            accepted_by_user: actor,
            signer_role:,
            acceptance_method:,
            content_sha256: version.content_sha256,
            evidence_digest: evidence_digest_for(locked_requirement, version, signer_role),
            idempotency_key_digest: key_digest,
            request_uuid:,
            retention_policy: policy_result.value,
            retain_until: retention_deadline(policy_result.value),
            accepted_at:
          )
          locked_requirement.association(:registration_consent).target = acceptance
          locked_requirement.update!(status: "accepted")
          record_audit(acceptance, locked_requirement)
          success(acceptance)
        end
      rescue ActiveRecord::RecordInvalid => error_record
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.consents.errors.invalid_acceptance"),
            code: "invalid_consent_acceptance",
            status: :unprocessable_entity,
            errors: error_record.record.errors.to_hash
          )
        )
      rescue ActiveRecord::RecordNotUnique
        existing = RegistrationConsent.find_by(idempotency_key_digest: key_digest) ||
          RegistrationConsent.find_by(request_uuid: request_uuid)
        return success(existing) if existing && replay_matches?(existing, requirement, key_digest)

        failure(error("acceptance_conflict"))
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

      attr_reader :requirement, :actor, :request_uuid, :acceptance_method,
                  :content_sha256, :idempotency_key, :accepted_at, :requirement_locked,
                  :idempotency_lookup

      def locked_requirement
        return requirement if requirement_locked

        RegistrationConsentRequirement
          .lock
          .includes(
            :registration,
            :registration_consent,
            consent_document_version: { consent_document: %i[versions consent_document_products] }
          )
          .find(requirement.id)
      end

      def valid_request_uuid?
        request_uuid.to_s.match?(RegistrationConsent::UUID_FORMAT)
      end

      def idempotency_key_digest
        @idempotency_key_digest ||= begin
          key = Core::IdempotencyKey.new(idempotency_key)
          Core::KeyedDigest.digest(namespace: "ticketing-consent-accept", value: key.to_s)
        end
      end

      def preloaded_idempotency_acceptance(key_digest)
        return RegistrationConsent.lock.find_by(idempotency_key_digest: key_digest) if idempotency_lookup == :unchecked
        return if idempotency_lookup == :not_found

        idempotency_lookup
      end

      def acceptable_version?(version)
        document = version.consent_document
        document.active? && %w[published retired].include?(version.status)
      end

      def signer_role_for(locked_requirement)
        if locked_requirement.acceptance_scope == "buyer"
          return [ nil, "consent_subject_mismatch" ] unless locked_requirement.subject_user_id == actor.id &&
            locked_requirement.registration.user_id == actor.id

          [ "buyer", nil ]
        else
          return [ nil, "consent_subject_unassigned" ] if locked_requirement.subject_user_id.blank?
          return [ nil, "consent_subject_mismatch" ] unless locked_requirement.subject_user_id == actor.id

          [ "attendee", nil ]
        end
      end

      def retention_deadline(policy)
        policy.retention_days && accepted_at + policy.retention_days.days
      end

      def evidence_digest_for(locked_requirement, version, signer_role)
        RegistrationConsent.evidence_digest_for(
          registration_id: locked_requirement.registration_id,
          subject_user_id: locked_requirement.subject_user_id,
          accepted_by_user_id: actor.id,
          version_id: version.id,
          content_sha256: version.content_sha256,
          signer_role:,
          acceptance_method:,
          accepted_at:,
          request_uuid:
        )
      end

      def replay_or_conflict(existing, locked_requirement, key_digest)
        return success(existing) if replay_matches?(existing, locked_requirement, key_digest)

        failure(error("acceptance_conflict"))
      end

      def replay_matches?(existing, locked_requirement, key_digest)
        existing.registration_consent_requirement_id == locked_requirement.id &&
          existing.idempotency_key_digest == key_digest &&
          existing.accepted_by_user_id == actor.id &&
          existing.request_uuid == request_uuid &&
          existing.acceptance_method == acceptance_method &&
          existing.content_sha256 == effective_content_sha256(locked_requirement)
      end

      def effective_content_sha256(locked_requirement)
        content_sha256.presence || locked_requirement.consent_document_version.content_sha256
      end

      def record_audit(acceptance, locked_requirement)
        Core::Audit::Record.call(
          audit_key: "ticketing-consent-accept-#{acceptance.request_uuid}",
          action: "ticketing.registration_consent.accepted",
          auditable_type: acceptance.class.name,
          auditable_id: acceptance.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          request_uuid: acceptance.request_uuid,
          audited_changes: { status: [ "pending", "accepted" ] },
          metadata: {
            registration_id: locked_requirement.registration_id,
            requirement_id: locked_requirement.id,
            consent_document_version_id: locked_requirement.consent_document_version_id,
            acceptance_scope: locked_requirement.acceptance_scope
          }
        ).value
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
