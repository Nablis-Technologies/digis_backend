  # frozen_string_literal: true

  module Ticketing
    module RegistrationDecisions
      # Shared authorization, audit, and replay boundaries for decision commands.
      module Support
      include Ticketing::Registrations::Support

      private

      def reviewer_authorized?(registration, actor)
        actor.present? && Events::AuthorizationResolver.can_manage_catalog?(actor, registration.event)
      end

      def decision_audit_key(action, registration, idempotency_key)
        digest = Core::IdempotencyKey.new(idempotency_key).digest
        "ticketing-registration-#{action}-#{registration.id}-#{digest}"
      end

      def decision_error(code)
        workflow_error(code)
      end

      def record_decision_audit!(action:, audit_key:, registration:, actor:, audited_changes:, metadata: {})
        unwrap(Core::Audit::Record.call(
          audit_key:,
          action: "ticketing.registration.#{action}",
          auditable_type: registration.class.name,
          auditable_id: registration.id,
          actor_type: actor&.class&.name,
          actor_id: actor&.id,
          audited_changes:,
          metadata: metadata.merge(event_id: registration.event_id)
        ))
      end

      def replayed_registration(audit_key)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit

        Ticketing::Registration.find(audit.auditable_id)
      end

      def halt(code)
        fail Ticketing::Registrations::Support::Halt, Core::BaseService::Result.failure(decision_error(code))
      end
      end
    end
  end
