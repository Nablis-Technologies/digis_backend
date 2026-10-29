# frozen_string_literal: true

require "digest"

module Marketing
  module PlacementAdmin
    # Keeps admin command idempotency and audit identity local to Marketing;
    # only Core's generic key, digest, lock, and audit primitives are shared.
    module CommandSupport
      private

      def normalized_key
        @normalized_key ||= Core::IdempotencyKey.new(@raw_idempotency_key)
      rescue ArgumentError => exception
        raise error(:invalid_idempotency_key, code: "invalid_idempotency_key", status: :bad_request,
          message: exception.message)
      end

      def idempotency_digest
        Core::KeyedDigest.digest(
          namespace: "marketing-placement-admin-idempotency", value: normalized_key.to_s
        )
      end

      def request_digest(payload)
        Core::KeyedDigest.digest(
          namespace: "marketing-placement-admin-request",
          value: ActiveSupport::JSON.encode(canonicalize(payload))
        )
      end

      def authorized?(permission)
        @actor&.super_admin? || @actor&.has_permission?(permission)
      end

      def error(key, code: key.to_s, status: :unprocessable_entity, errors: nil, message: nil)
        Core::BusinessError.new(
          message || I18n.t("marketing.errors.#{key}", default: "The request could not be completed."),
          code:, status:, errors:
        )
      end

      def resource_class
        self.class::RESOURCE_CLASS
      end

      def not_found_error_key
        self.class::NOT_FOUND_ERROR_KEY
      end

      def replay_result(audit_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit

        metadata = audit.metadata.deep_stringify_keys
        if metadata["request_digest"] == request_digest && audit.auditable_type == resource_class.name
          return replay_resource(resource_class, audit.auditable_id)
        end

        failure(error(:idempotency_conflict, status: :conflict))
      end

      def replay_resource(resource_class, resource_id)
        record = resource_class.find_by(id: resource_id)
        return success(record) if record

        failure(error(:idempotency_replay_missing, code: "idempotency_replay_missing", status: :conflict))
      end

      def audit!(audit_key:, action:, record:, request_digest:, reason:, previous_status: nil)
        audit_record!(
          audit_key:, action:, record:, request_digest:, reason:,
          changes: { "status" => [ previous_status, record.status ], "version" => record.version }
        )
      end

      def audit_record!(audit_key:, action:, record:, request_digest:, reason:, changes:)
        result = Core::Audit::Record.call(
          audit_key:, action:, auditable_type: record.class.name, auditable_id: record.id,
          actor_type: @actor.class.name, actor_id: @actor.id,
          audited_changes: changes,
          metadata: { "request_digest" => request_digest, "reason" => reason }
        )
        raise result.error if result.failure?

        result.value
      end

      def canonicalize(value)
        case value
        when Hash
          value.to_h.stringify_keys.sort.to_h do |key, child|
            [ key, canonicalize(child) ]
          end
        when Array
          value.map { |child| canonicalize(child) }
        else
          value.respond_to?(:as_json) ? value.as_json : value
        end
      end

      def handle_errors
        yield
      rescue ActiveRecord::RecordInvalid => exception
        key = "invalid_#{exception.record.model_name.element}"
        failure(error(key, errors: exception.record.errors.to_hash))
      rescue ActiveRecord::RecordNotUnique
        failure(error(:idempotency_conflict, status: :conflict))
      rescue ActiveRecord::RecordNotFound
        failure(error(not_found_error_key, status: :not_found))
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, status: :conflict))
      rescue Core::Error => exception
        failure(exception)
      end
    end
  end
end
