# frozen_string_literal: true

module Core
  module Retention
    class ReleaseHold < Core::BaseService
      def initialize(hold:, actor:, idempotency_key:)
        @hold = hold
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        Core::IdempotencyKey.new(idempotency_key)
        return failure(unauthorized) unless platform_admin?

        DataRetentionHold.transaction do
          requested_hold = DataRetentionHold.find(hold.id)
          lock_scope!(requested_hold)
          locked_hold = DataRetentionHold.lock.find(requested_hold.id)
          release_audit = ensure_release_key_available!(locked_hold, key)

          unless locked_hold.released?
            locked_hold.update!(released_by: actor, released_at: [ Time.current, locked_hold.starts_at ].max)
          end
          record_release_audit!(locked_hold, key) unless release_audit
          success(locked_hold)
        end
      rescue ArgumentError
        failure(error("invalid_idempotency_key"))
      rescue Core::Audit::Record::ReplayConflict
        failure(error("idempotency_conflict"))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error("invalid_hold", errors: exception.record.errors.to_hash))
      end

      private

      attr_reader :hold, :actor, :idempotency_key

      def key
        @key ||= Core::IdempotencyKey.new(idempotency_key).to_s
      end

      def ensure_release_key_available!(locked_hold, release_key)
        audit = Core::AuditLog.find_by(audit_key: release_audit_key(release_key))
        if audit && audit.auditable_id != locked_hold.id
          raise Core::Audit::Record::ReplayConflict, "release idempotency key conflicts with another hold"
        end

        audit = Core::AuditLog
          .where(action: "retention.hold.released", auditable_type: locked_hold.class.name, auditable_id: locked_hold.id)
          .first
        return audit if audit.nil? || audit.metadata["idempotency_key"] == release_key

        raise Core::Audit::Record::ReplayConflict, "release idempotency key conflicts with this hold"
      end

      def record_release_audit!(hold, release_key)
        result = Core::Audit::Record.call(
          audit_key: release_audit_key(release_key),
          action: "retention.hold.released",
          auditable_type: hold.class.name,
          auditable_id: hold.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { status: [ "active", "released" ] },
          metadata: { idempotency_key: release_key }
        )
        raise result.error if result.failure?
      end

      def release_audit_key(release_key)
        "core-retention-hold-release:#{release_key}"
      end

      def lock_scope!(locked_hold)
        keys = {
          event: locked_hold.event_id,
          registration: locked_hold.registration_id,
          user: locked_hold.user_id
        }.compact.sort_by { |type, _id| type.to_s }
          .map { |type, id| [ "retention-scope", type, id ] }
        Core::Database::AdvisoryLock.acquire_all!(*keys)
      end

      def platform_admin?
        actor&.has_role?("SUPER_ADMIN") || actor&.has_role?("CORE_ADMIN")
      end

      def unauthorized
        error("unauthorized", status: :forbidden)
      end

      def error(code, status: :unprocessable_entity, errors: nil)
        Core::BusinessError.new(
          I18n.t("core.retention.errors.#{code}"), code:, status:, errors:
        )
      end
    end
  end
end
