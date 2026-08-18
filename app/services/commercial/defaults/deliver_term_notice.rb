# frozen_string_literal: true

module Commercial
  module Defaults
    # Delivers one exact platform-default version into the Commercial terms
    # inbox. The unique organization/version/method key and audit fingerprint
    # make retries safe without treating a different request as a replay.
    class DeliverTermNotice < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(organization:, version:, actor:, idempotency_key:, delivery_method: "in_app")
        @organization = organization
        @version = version
        @actor = actor
        @idempotency_key = idempotency_key
        @delivery_method = delivery_method.to_s
      end

      def call
        return failure(unauthorized_error("commercial.activate")) unless actor&.has_permission?("commercial.activate")

        prepare_request!
        ActiveRecord::Base.transaction do
          locked_version = FeeScheduleVersion.includes(:fee_schedule, :legal_document_version).lock.find(version.id)
          locked_organization = Organizations::Organization.lock.find(organization.id)
          deliver_locked(locked_organization, locked_version)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(governance_error("invalid_idempotency_key", code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordNotUnique
        failure(governance_error("term_notice_conflict", code: "term_notice_conflict"))
      rescue ActiveRecord::RecordInvalid => error
        failure(governance_error("invalid_term_notice", code: "invalid_term_notice", errors: error.record.errors.to_hash))
      end

      private

      attr_reader :organization, :version, :actor, :idempotency_key, :delivery_method,
                  :key_digest, :fingerprint

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("term-notice", idempotency_key)
      end

      def deliver_locked(locked_organization, locked_version)
        return failure(governance_error("invalid_term_notice", code: "invalid_term_notice")) unless delivery_method.in?(TermNotice::DELIVERY_METHODS)
        return failure(governance_error("state_conflict", code: "state_conflict")) unless locked_version.fee_schedule.schedule_type == "platform_default" && locked_version.status.in?(%w[scheduled active])
        return failure(governance_error("legal_version_required", code: "legal_version_required")) if locked_version.legal_document_version.blank?
        return failure(governance_error("legal_version_not_published", code: "legal_version_not_published")) unless locked_version.legal_document_version.published?
        return failure(governance_error("effective_time_invalid", code: "effective_time_invalid")) if locked_version.effective_from.blank? || locked_version.effective_from <= Time.current

        @fingerprint = fingerprint_for(
          action: "term_notice", organization_id: locked_organization.id, fee_schedule_version_id: locked_version.id,
          legal_document_version_id: locked_version.legal_document_version_id, delivery_method:, actor_id: actor.id
        )
        replay = replay_status(audit_key:, actor:, fingerprint:)
        return success(existing_notice(locked_organization, locked_version)) if replay == :replay
        return failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if replay == :conflict

        existing = TermNotice.lock.find_by(
          organization_id: locked_organization.id, fee_schedule_version_id: locked_version.id,
          delivery_method:
        )
        return failure(governance_error("term_notice_conflict", code: "term_notice_conflict")) if existing

        delivered_at = Time.current
        notice = TermNotice.create!(
          organization: locked_organization, fee_schedule_version: locked_version,
          legal_document_version: locked_version.legal_document_version,
          delivery_method:, status: "delivered", available_at: delivered_at, delivered_at:,
          evidence_digest: TermNotice.evidence_digest_for(
            organization_id: locked_organization.id, fee_schedule_version_id: locked_version.id,
            legal_document_version_id: locked_version.legal_document_version_id,
            delivery_method:, delivered_at:
          ),
          idempotency_key_digest: key_digest
        )
        record_transition!(
          target: notice, actor:, audit_key:, action: "commercial.term_notice.delivered",
          audited_changes: { "status" => [ nil, "delivered" ], "fee_schedule_version_id" => locked_version.id },
          metadata: { "request_fingerprint" => fingerprint },
          topic: "commercial", event_type: "commercial.term_notice.delivered",
          payload: {
            term_notice_id: notice.id, organization_id: notice.organization_id,
            fee_schedule_version_id: notice.fee_schedule_version_id,
            legal_document_version_id: notice.legal_document_version_id,
            delivery_method: notice.delivery_method, delivered_at: delivered_at.iso8601(6)
          }
        )
        success(notice)
      end

      def existing_notice(locked_organization, locked_version)
        TermNotice.find_by!(
          organization_id: locked_organization.id, fee_schedule_version_id: locked_version.id,
          delivery_method:
        )
      end

      def audit_key
        "commercial-term-notice-#{key_digest}"
      end
    end
  end
end
