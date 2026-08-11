# frozen_string_literal: true

require "digest"
require "json"

module Commercial
  module Governance
    # Shared mechanics for Commercial commands. Domain services still own their
    # state machine, while this module keeps locking, request fingerprints,
    # synchronous audit, and bounded outbox evidence consistent.
    module CommandSupport
      private

      def normalize_idempotency_key(raw_key)
        Core::IdempotencyKey.new(raw_key).to_s
      end

      def idempotency_digest(command, raw_key)
        Core::IdempotencyKey.new("commercial:#{command}:#{raw_key}").digest
      end

      def fingerprint_for(attributes)
        Digest::SHA256.hexdigest(JSON.generate(canonicalize(attributes)))
      end

      def canonicalize(value)
        case value
        when Hash
          value.stringify_keys.sort.to_h { |key, child| [ key, canonicalize(child) ] }
        when Array
          value.map { |child| canonicalize(child) }
        when Time, DateTime
          value.iso8601(6)
        when Date
          value.iso8601
        else
          value
        end
      end

      def governance_error(key, code: key, status: :unprocessable_entity, errors: nil, **options)
        Core::BusinessError.new(
          I18n.t("commercial.governance.errors.#{key}", **options),
          code:, status:, errors:
        )
      end

      def unauthorized_error(permission)
        governance_error("unauthorized", code: "unauthorized", status: :forbidden, permission:)
      end

      def record_transition!(target:, actor:, audit_key:, action:, audited_changes:, metadata:,
                             topic:, event_type:, payload:, outbox_key: audit_key)
        audit = Core::Audit::Record.call(
          audit_key:, action:, auditable_type: target.class.name, auditable_id: target.id,
          actor_type: actor&.class&.name, actor_id: actor&.id,
          audited_changes:, metadata:
        )
        raise audit.error if audit.failure?

        outbox = Core::Outbox::Publish.call(
          topic:, event_type:, aggregate: target, payload:, idempotency_key: outbox_key
        )
        raise outbox.error if outbox.failure?

        outbox.value
      end

      def audit_exists?(audit_key)
        Core::AuditLog.exists?(audit_key:)
      end

      def replay_status(audit_key:, actor:, fingerprint:)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit

        same_request = audit.metadata["request_fingerprint"] == fingerprint &&
          audit.actor_type == actor&.class&.name && audit.actor_id == actor&.id
        same_request ? :replay : :conflict
      end
    end
  end
end
