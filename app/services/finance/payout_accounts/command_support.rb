# frozen_string_literal: true

module Finance
  module PayoutAccounts
    # Centralizes payout-destination command identity. The audit key is the
    # database-backed idempotency boundary; the request digest prevents a
    # client from replaying the same key against a different destination or
    # lifecycle intent.
    module CommandSupport
      private

      def normalize_command_key(raw_key)
        Core::IdempotencyKey.new(raw_key)
      end

      def command_audit_key(operation, key)
        "finance-payout-account-#{operation}-#{key.digest}"
      end

      def command_request_digest(operation:, account_id:, actor:, identity: {})
        Core::KeyedDigest.digest(
          namespace: "finance-payout-account-idempotency",
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
        return replay_account(audit) if metadata[:request_digest] == request_digest

        failure(command_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
      end

      def replay_account(audit)
        account_id = audit.metadata.deep_symbolize_keys[:account_id]
        account = PayoutAccount.find_by(id: account_id)
        return success(account) if account

        failure(command_error(
          :payout_account_replay_missing,
          code: "payout_account_replay_missing", status: :conflict
        ))
      end

      def command_replay_matches?(audit_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key:)
        audit && audit.metadata.deep_symbolize_keys[:request_digest] == request_digest
      end

      def command_error(key, code: key.to_s, status: :unprocessable_entity, errors: nil)
        Core::BusinessError.new(I18n.t("finance.errors.#{key}"), code:, status:, errors:)
      end

      def finance_error(key, code: key, status: :unprocessable_entity, errors: nil)
        command_error(key, code:, status:, errors:)
      end

      def error(key, code, status = :unprocessable_entity)
        command_error(key, code:, status:)
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
end
