# frozen_string_literal: true

module Core
  module Retention
    # Places one immutable legal hold and records it exactly once for a retry key.
    # The scope lock makes placement serialize with purge and release commands.
    class PlaceHold < Core::BaseService
      def initialize(actor:, scope:, category: nil, reason_code:, starts_at:, expires_at: nil, idempotency_key:)
        @actor = actor
        @scope = normalize_scope(scope)
        @category = category.presence
        @reason_code = reason_code
        @starts_at = normalize_time(starts_at)
        @expires_at = normalize_time(expires_at)
        @idempotency_key = idempotency_key
      end

      def call
        key = Core::IdempotencyKey.new(idempotency_key).to_s
        return failure(unauthorized) unless platform_admin?

        DataRetentionHold.transaction do
          # Lock the affected event, registration, and user scopes before the
          # idempotency lookup so concurrent commands share one ordering.
          lock_scope!
          existing = DataRetentionHold.lock.find_by(idempotency_key: key)
          return existing_result(existing, key) if existing

          hold = DataRetentionHold.create!(
            **scope,
            category:,
            reason_code:,
            placed_by: actor,
            starts_at:,
            expires_at:,
            idempotency_key: key
          )
          record_placement_audit!(hold, key)
          success(hold)
        end
      rescue ArgumentError
        failure(error("invalid_idempotency_key"))
      rescue Core::Audit::Record::ReplayConflict
        failure(error("idempotency_conflict"))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error("invalid_hold", errors: exception.record.errors.to_hash))
      rescue ActiveRecord::RecordNotUnique
        replay = DataRetentionHold.find_by(idempotency_key: key)
        replay ? existing_result(replay, key) : failure(error("hold_conflict"))
      end

      private

      attr_reader :actor, :scope, :category, :reason_code, :starts_at, :expires_at, :idempotency_key

      def normalize_scope(attributes)
        attributes.to_h.stringify_keys.symbolize_keys.slice(:event_id, :registration_id, :user_id)
          .compact_blank
      end

      def normalize_time(value)
        return if value.blank?
        return value.to_time if value.respond_to?(:to_time)

        Time.zone.parse(value.to_s)
      end

      def existing_result(existing, key)
        if same_request?(existing, key)
          audit = Core::AuditLog.find_by(audit_key: placement_audit_key(key))
          if audit && audit.auditable_id != existing.id
            return failure(error("idempotency_conflict"))
          end
          record_placement_audit!(existing, key) unless audit
          return success(existing)
        end

        failure(error("idempotency_conflict"))
      end

      def record_placement_audit!(hold, key)
        result = Core::Audit::Record.call(
          audit_key: placement_audit_key(key),
          action: "retention.hold.placed",
          auditable_type: hold.class.name,
          auditable_id: hold.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { status: [ nil, "active" ] },
          metadata: { idempotency_key: key }
        )
        raise result.error if result.failure?
      end

      def placement_audit_key(key)
        "core-retention-hold-place:#{key}"
      end

      def lock_scope!
        # Sorting scope types prevents two commands from acquiring shared locks
        # in opposite orders when a hold targets multiple scopes.
        keys = scope.sort_by { |type, _id| type.to_s }
          .map { |type, id| [ "retention-scope", type, id ] }
        Core::Database::AdvisoryLock.acquire_all!(*keys)
      end

      def same_request?(existing, key)
        existing.idempotency_key == key &&
          existing.attributes.slice("event_id", "registration_id", "user_id", "category", "reason_code",
                                    "starts_at", "expires_at") == requested_attributes
      end

      def requested_attributes
        {
          "event_id" => scope[:event_id],
          "registration_id" => scope[:registration_id],
          "user_id" => scope[:user_id],
          "category" => category,
          "reason_code" => reason_code,
          "starts_at" => starts_at,
          "expires_at" => expires_at
        }.stringify_keys
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
