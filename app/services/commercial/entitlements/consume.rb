# frozen_string_literal: true

module Commercial
  module Entitlements
    # Consumes the reserved first-event benefit for one accepted paid order.
    #
    # Checkout will call this command synchronously before applying the benefit.
    # The organization lock is deliberately shared with publication
    # reconciliation, making the reservation check and terminal transition one
    # serialized operation even when publication delivery is delayed.
    class Consume < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(event:, idempotency_key:)
        @event = event
        @idempotency_key = idempotency_key
      end

      def call
        return failure(entitlement_error(:event_required)) unless event_id

        prepare_request!
        ActiveRecord::Base.transaction do
          authoritative_event = event.respond_to?(:organization_id) ? event : Events::Event.find_by(id: event_id)
          return failure(entitlement_error(:event_not_published)) unless published_event?(authoritative_event)

          reconciled = ReconcileFirstEvent.call(event: authoritative_event)
          return reconciled if reconciled.failure?

          entitlement = locked_reconciled_entitlement(reconciled.value)
          return failure(entitlement_error(:entitlement_unavailable)) unless entitlement

          consume_locked(entitlement, authoritative_event)
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

      attr_reader :event, :idempotency_key, :key_digest, :fingerprint

      def event_id
        event.respond_to?(:id) ? event.id : event.presence
      end

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("entitlement-consume", @idempotency_key)
      end

      def published_event?(authoritative_event)
        authoritative_event&.status == "published" && authoritative_event.published_at.present?
      end

      def locked_reconciled_entitlement(entitlement)
        return unless entitlement&.persisted?

        Commercial::ProgramEntitlement.lock.find(entitlement.id)
      end

      def consume_locked(entitlement, authoritative_event)
        audit_key = "commercial-entitlement-consume-#{entitlement.id}-#{key_digest}"
        replay = replay_status(
          audit_key:, actor: nil,
          fingerprint: request_fingerprint(entitlement, authoritative_event)
        )
        return success(entitlement) if replay == :replay
        return failure(governance_error("idempotency_conflict", code: "idempotency_conflict")) if replay == :conflict

        if entitlement.status == "consumed"
          if consumed_by_event?(entitlement, authoritative_event)
            return failure(governance_error("idempotency_conflict", code: "idempotency_conflict"))
          end

          return failure(entitlement_error(:entitlement_unavailable))
        end

        unless entitlement.status == "reserved" && entitlement.reserved_event_id == authoritative_event.id
          return failure(entitlement_error(:entitlement_unavailable))
        end

        before = entitlement.attributes.slice("status", "reserved_event_id", "reserved_at", "consumed_at")
        entitlement.update!(
          status: "consumed", reserved_event_id: nil, reserved_at: nil, consumed_at: Time.current
        )
        record_transition!(
          target: entitlement, actor: nil, audit_key:,
          action: "commercial.program_entitlement.consumed",
          audited_changes: before.merge(
            "status" => [ before.fetch("status"), "consumed" ],
            "reserved_event_id" => [ before.fetch("reserved_event_id"), nil ],
            "consumed_at" => [ before["consumed_at"], entitlement.consumed_at ]
          ),
          metadata: {
            "request_fingerprint" => request_fingerprint(entitlement, authoritative_event),
            "idempotency_key_digest" => key_digest,
            "source_event_id" => authoritative_event.id
          },
          topic: "commercial", event_type: "commercial.program_entitlement.consumed",
          payload: {
            program_entitlement_id: entitlement.id,
            organization_id: entitlement.organization_id,
            event_id: authoritative_event.id,
            status: "consumed"
          }
        )
        success(entitlement)
      end

      def request_fingerprint(entitlement, authoritative_event)
        @fingerprint ||= fingerprint_for(
          action: "consume", entitlement_id: entitlement.id,
          program_id: entitlement.program_id, organization_id: entitlement.organization_id,
          event_id: authoritative_event.id, idempotency_key_digest: key_digest
        )
      end

      def consumed_by_event?(entitlement, authoritative_event)
        Core::AuditLog.where(
          auditable_type: entitlement.class.name,
          auditable_id: entitlement.id,
          action: "commercial.program_entitlement.consumed"
        ).where("metadata ->> 'source_event_id' = ?", authoritative_event.id).exists?
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
