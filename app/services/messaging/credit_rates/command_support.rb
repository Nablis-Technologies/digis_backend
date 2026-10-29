# frozen_string_literal: true

require "digest"

module Messaging
  module CreditRates
    # Shared normalization, idempotency, audit, and error translation for rate
    # lifecycle commands. Rate commands mutate only their versioned definition;
    # payment and credit-ledger side effects remain in their owning services.
    module CommandSupport
      private

      def normalized_key
        @normalized_key ||= Core::IdempotencyKey.new(@raw_idempotency_key)
      end

      def idempotency_digest
        Core::KeyedDigest.digest(namespace: "messaging-credit-rate", value: normalized_key.to_s)
      end

      def request_digest(attributes)
        Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(attributes.deep_stringify_keys))
      end

      def authorized?(permission)
        @actor&.super_admin? || @actor&.has_permission?(permission)
      end

      def error(key, status: :unprocessable_entity, errors: nil)
        Core::BusinessError.new(
          I18n.t("messaging.errors.#{key}"), code: key.to_s, status:, errors:
        )
      end

      def audit!(key:, action:, rate:, changes:, metadata: {})
        result = Core::Audit::Record.call(
          audit_key: key, action:, auditable_type: rate.class.name, auditable_id: rate.id,
          actor_type: @actor.class.name, actor_id: @actor.id,
          audited_changes: changes, metadata: metadata.merge("idempotency_key" => normalized_key.to_s)
        )
        raise result.error if result.failure?

        result.value
      end

      def handle_errors
        yield
      rescue ArgumentError
        failure(error(:invalid_idempotency_key))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_credit_operation, errors: exception.record.errors.to_hash))
      rescue ActiveRecord::RecordNotUnique
        failure(error(:credit_idempotency_conflict, status: :conflict))
      rescue Core::Error => exception
        failure(exception)
      end
    end
  end
end
