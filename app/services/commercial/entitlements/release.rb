# frozen_string_literal: true

module Commercial
  module Entitlements
    # Releases an unused first-event reservation after the event closes.
    #
    # Consumed rows are terminal and have no active event pointer by design, so
    # this command uses the immutable consumed audit metadata to recognize a
    # cancellation after consumption and deliberately leaves the benefit intact.
    class Release < Core::BaseService
      include Commercial::Governance::CommandSupport

      RELEASE_REASONS = %w[event_cancelled event_completed event_ended].freeze

      def initialize(event:, reason:, idempotency_key:)
        @event = event
        @reason = reason.to_s
        @idempotency_key = idempotency_key
      end

      def call
        return failure(entitlement_error(:event_required)) unless event_id
        return failure(entitlement_error(:invalid_release_reason)) unless reason.in?(RELEASE_REASONS)

        prepare_request!
        ActiveRecord::Base.transaction do
          authoritative_event = Events::Event.preload(:event_dates).find_by(id: event_id)
          return success(nil) unless authoritative_event
          return failure(entitlement_error(:event_not_closed)) unless release_reason_matches?(authoritative_event)

          organization = Organizations::Organization.lock.find(authoritative_event.organization_id)
          entitlement = find_entitlement_for_release(authoritative_event, organization)
          return failure(entitlement_error(:entitlement_ambiguous)) if entitlement == :ambiguous
          return success(nil) unless entitlement
          return success(entitlement) if entitlement.status == "consumed"

          release_locked(entitlement, authoritative_event)
        end
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.governance.errors.invalid_idempotency_key"),
            code: "invalid_idempotency_key", status: :unprocessable_entity
          )
        )
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.governance.errors.invalid_record"),
            code: "invalid_record", status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      end

      private

      attr_reader :event, :reason, :idempotency_key, :key_digest, :fingerprint

      def event_id
        event.respond_to?(:id) ? event.id : event.presence
      end

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("entitlement-release", @idempotency_key)
      end

      def release_reason_matches?(authoritative_event)
        case reason
        when "event_cancelled"
          authoritative_event.status == "cancelled"
        when "event_completed"
          authoritative_event.status == "completed"
        when "event_ended"
          event_ended?(authoritative_event)
        else
          false
        end
      end

      def event_ended?(authoritative_event)
        dates = authoritative_event.event_dates
        dates.present? && dates.all? do |event_date|
          event_date.status.in?(%w[cancelled completed]) || event_date.ends_at <= Time.current
        end
      end

      def find_entitlement_for_release(authoritative_event, organization)
        reserved = Commercial::ProgramEntitlement.lock.where(
          organization_id: organization.id,
          status: "reserved",
          reserved_event_id: authoritative_event.id
        ).to_a
        return :ambiguous if reserved.length > 1
        return reserved.first if reserved.first

        historical_ids = Core::AuditLog.where(
          auditable_type: "Commercial::ProgramEntitlement",
          action: %w[commercial.program_entitlement.consumed commercial.program_entitlement.released]
        ).where("metadata ->> 'source_event_id' = ?", authoritative_event.id).pluck(:auditable_id)
        Commercial::ProgramEntitlement.lock.where(
          id: historical_ids, organization_id: organization.id
        ).order(:id).first
      end

      def release_locked(entitlement, authoritative_event)
        audit_key = "commercial-entitlement-release-#{entitlement.id}-#{key_digest}"
        replay = replay_status(
          audit_key:, actor: nil,
          fingerprint: request_fingerprint(entitlement, authoritative_event)
        )
        return success(entitlement) if replay == :replay
        return failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if replay == :conflict

        if entitlement.status == "released"
          return failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if released_audit_exists?(entitlement)

          return success(entitlement)
        end
        return success(entitlement) if entitlement.status == "consumed"
        return failure(entitlement_error(:entitlement_unavailable)) unless entitlement.status == "reserved"

        before = entitlement.attributes.slice("status", "reserved_event_id", "reserved_at", "released_at")
        entitlement.update!(
          status: "released", reserved_event_id: nil, reserved_at: nil, released_at: Time.current
        )
        record_transition!(
          target: entitlement, actor: nil, audit_key:,
          action: "commercial.program_entitlement.released",
          audited_changes: before.merge(
            "status" => [ before.fetch("status"), "released" ],
            "reserved_event_id" => [ before.fetch("reserved_event_id"), nil ],
            "released_at" => [ before["released_at"], entitlement.released_at ]
          ),
          metadata: {
            "request_fingerprint" => request_fingerprint(entitlement, authoritative_event),
            "idempotency_key_digest" => key_digest,
            "source_event_id" => authoritative_event.id,
            "reason" => reason
          },
          topic: "commercial", event_type: "commercial.program_entitlement.released",
          payload: {
            program_entitlement_id: entitlement.id,
            organization_id: entitlement.organization_id,
            event_id: authoritative_event.id,
            reason:,
            status: "released"
          }
        )
        success(entitlement)
      end

      def request_fingerprint(entitlement, authoritative_event)
        @fingerprint ||= fingerprint_for(
          action: "release", entitlement_id: entitlement.id,
          program_id: entitlement.program_id, organization_id: entitlement.organization_id,
          event_id: authoritative_event.id, reason:, idempotency_key_digest: key_digest
        )
      end

      def released_audit_exists?(entitlement)
        Core::AuditLog.exists?(
          auditable_type: entitlement.class.name,
          auditable_id: entitlement.id,
          action: "commercial.program_entitlement.released"
        )
      end

      def governance_error(key, code: key, status: :unprocessable_entity, errors: nil, **options)
        Core::BusinessError.new(
          I18n.t("commercial.governance.errors.#{key}", **options), code:, status:, errors:
        )
      end

      def entitlement_error(key)
        Core::BusinessError.new(
          I18n.t("commercial.entitlements.errors.#{key}"),
          code: key.to_s, status: :unprocessable_entity
        )
      end
    end
  end
end
