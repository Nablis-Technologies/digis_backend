# frozen_string_literal: true

module Core
  # Shares provider-agnostic idempotency and audit mechanics across payout
  # commands without coupling Core to a domain's record or error type.
  module PayoutCommandSupport
    private

    def normalize_command_key(raw_key)
      Core::IdempotencyKey.new(raw_key)
    end

    def command_audit_key(operation, key)
      "#{payout_command_audit_prefix}-#{operation}-#{key.digest}"
    end

    def command_request_digest(operation:, account_id:, actor:, identity: {})
      Core::KeyedDigest.digest(
        namespace: payout_command_identity_namespace,
        value: ActiveSupport::JSON.encode(
          canonicalize(
            operation:, account_id:,
            actor_type: actor&.class&.name, actor_id: actor&.id,
            identity:
          )
        )
      )
    end

    def replay_result(audit_key:, request_digest:)
      audit = Core::AuditLog.find_by(audit_key:)
      return unless audit

      metadata = audit.metadata.deep_symbolize_keys
      return replay_target(audit) if metadata[:request_digest] == request_digest

      failure(command_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
    end

    def command_replay_matches?(audit_key:, request_digest:)
      audit = Core::AuditLog.find_by(audit_key:)
      audit && audit.metadata.deep_symbolize_keys[:request_digest] == request_digest
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
        value
      end
    end
  end
end
