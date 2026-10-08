# frozen_string_literal: true

module Events
  module StaffAssignments
    class Revoke < Core::BaseService
      def initialize(assignment:, actor:, idempotency_key:)
        @assignment = assignment
        @actor = actor
        @idempotency_key_input = idempotency_key
      end

      def call
        key = build_idempotency_key
        return failure(invalid_idempotency_key) unless key

        result = nil
        Events::Event.transaction do
          event = Events::Event.lock.find(assignment.event_id)
          locked = Events::EventStaffAssignment.lock.find(assignment.id)
          unless Events::AuthorizationResolver.can_assign?(actor, event, locked.role)
            result = permission_error
            next
          end

          audit_key = revoke_audit_key(key, locked)
          replay = Core::AuditLog.find_by(audit_key:)
          if replay
            result = replay_request?(replay, locked, key) ? success(locked) : idempotency_conflict
            next
          end
          if locked.status == "revoked"
            result = success(locked)
            next
          end

          previous_status = locked.status
          locked.update!(status: "revoked")
          request_digest = revoke_request_digest(key, locked)
          locked.record_audit!(
            "event.staff.revoked",
            actor:,
            audit_key:,
            audited_changes: { status: [ previous_status, "revoked" ] },
            metadata: { request_digest: }
          )
          publish_scanner_revocation!(locked) if locked.role == "scanner"
          result = success(locked)
        end
        result
      rescue ActiveRecord::RecordNotFound
        failure(Core::BusinessError.new(
          I18n.t("errors.not_found", model: "event staff assignment"),
          code: "not_found",
          status: :not_found
        ))
      rescue ActiveRecord::RecordInvalid => exception
        failure(Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.revoke"),
          code: "invalid_assignment",
          status: :unprocessable_entity,
          errors: exception.record.errors.to_hash
        ))
      rescue Core::Audit::Record::ReplayConflict
        idempotency_conflict
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :assignment, :actor, :idempotency_key_input

      def build_idempotency_key
        Core::IdempotencyKey.new(idempotency_key_input)
      rescue ArgumentError
        nil
      end

      def revoke_audit_key(key, locked)
        Core::KeyedDigest.digest(
          namespace: "events/staff-assignment-revoke/#{locked.id}/#{actor.id}",
          value: key.digest
        )
      end

      def revoke_request_digest(key, locked)
        Core::KeyedDigest.digest(
          namespace: "events/staff-assignment-revoke-request",
          value: ActiveSupport::JSON.encode(assignment_id: locked.id, actor_id: actor.id, key: key.digest)
        )
      end

      def replay_request?(audit, locked, key)
        audit.metadata.deep_stringify_keys["request_digest"] == revoke_request_digest(key, locked)
      end

      def publish_scanner_revocation!(locked)
        result = Core::Outbox::Publish.call(
          topic: "events",
          event_type: "events.staff_assignment.revoked",
          aggregate: locked,
          payload: { event_staff_assignment_id: locked.id, actor_id: actor.id },
          idempotency_key: Core::KeyedDigest.digest(
            namespace: "events/staff-assignment-revocation",
            value: locked.id
          )
        )
        raise result.error if result.failure?
      end

      def invalid_idempotency_key
        Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.invalid_idempotency_key"),
          code: "invalid_idempotency_key",
          status: :bad_request
        )
      end

      def idempotency_conflict
        failure Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.idempotency_conflict"),
          code: "idempotency_conflict",
          status: :conflict
        )
      end

      def permission_error
        failure Core::BusinessError.new(
          I18n.t("authorization.errors.unauthorized"),
          code: "forbidden",
          status: :forbidden
        )
      end
    end
  end
end
