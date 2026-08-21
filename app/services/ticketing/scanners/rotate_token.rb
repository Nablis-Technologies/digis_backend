# frozen_string_literal: true

require "securerandom"

module Ticketing
  module Scanners
    # Replaces a scanner credential atomically. A rotation never reuses the
    # previous digest, and the new plaintext is returned exactly once.
    class RotateToken < Core::BaseService
      Result = Data.define(:device, :token, :replayed) do
        def replayed? = replayed
      end

      def initialize(device:, actor:, idempotency_key:)
        @device = device
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        return failure(error(:token_rotation_forbidden, :forbidden)) unless authorized?

        device = nil
        ActiveRecord::Base.transaction do
          device = Ticketing::ScannerDevice.lock.find(@device.id)
          receipt_result = IdempotencyReceipt.call(
            operation: "rotate_token", device:, actor: @actor, idempotency_key:
          )
          return failure(receipt_result.error) if receipt_result.failure?
          receipt = receipt_result.value
          return success(Result.new(device:, token: nil, replayed: true)) if receipt.replayed?
          return failure(error(:device_revoked, :conflict)) if device.status == "revoked"

          token = SecureRandom.hex(32)

          device.update!(token_digest: Ticketing::ScannerDevice.token_digest_for(token:))
          device.record_audit!(
            "ticketing.scanner_device.token_rotated",
            actor: @actor,
            audited_changes: { credential_rotated: true },
            audit_key: "ticketing-scanner-token-rotated-#{receipt.receipt.id}"
          )

          @result = Result.new(device:, token:, replayed: false)
        end

        success(@result)
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_device, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

      attr_reader :idempotency_key

      def authorized?
        Events::AuthorizationResolver.organization_admin?(@actor, @device.organization)
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.#{key}"),
          code: key,
          status:,
          errors:
        )
      end
    end
  end
end
