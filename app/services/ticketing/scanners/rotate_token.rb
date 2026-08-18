# frozen_string_literal: true

require "securerandom"

module Ticketing
  module Scanners
    # Replaces a scanner credential atomically. A rotation never reuses the
    # previous digest, and the new plaintext is returned exactly once.
    class RotateToken < Core::BaseService
      Result = Data.define(:device, :token)

      def initialize(device:, actor:)
        @device = device
        @actor = actor
      end

      def call
        return failure(error(:token_rotation_forbidden, :forbidden)) unless authorized?

        token = SecureRandom.hex(32)
        device = nil
        ActiveRecord::Base.transaction do
          device = Ticketing::ScannerDevice.lock.find(@device.id)
          return failure(error(:device_revoked, :conflict)) if device.status == "revoked"

          device.update!(token_digest: Ticketing::ScannerDevice.token_digest_for(token:))
          device.record_audit!(
            "ticketing.scanner_device.token_rotated",
            actor: @actor,
            audited_changes: { credential_rotated: true }
          )
        end

        success(Result.new(device:, token:))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_device, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

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
