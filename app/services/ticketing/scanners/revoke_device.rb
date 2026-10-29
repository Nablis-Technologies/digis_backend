# frozen_string_literal: true

module Ticketing
  module Scanners
    # Revokes a scanner credential and its event assignments atomically. The
    # device remains auditable, while future online authentication is denied.
    class RevokeDevice < Core::BaseService
      def initialize(device:, actor:, reason:, idempotency_key:)
        @device = device
        @actor = actor
        @reason = reason.to_s.strip
        @idempotency_key = idempotency_key
      end

      def call
        return failure(error(:device_revoke_forbidden, :forbidden)) unless authorized?
        return failure(error(:revoke_reason_required, :bad_request)) if reason.blank?

        ActiveRecord::Base.transaction do
          device.lock!
          receipt_result = IdempotencyReceipt.call(
            operation: "revoke", device:, actor:, idempotency_key:, request_identity: { reason: }
          )
          return failure(receipt_result.error) if receipt_result.failure?
          return success(device) if receipt_result.value.replayed?
          return success(device) if device.status == "revoked"

          now = Time.current
          device.update!(status: "revoked", revoked_at: now)
          device.assignments.lock.find_each do |assignment|
            Ticketing::ScannerSession.where(
              scanner_device_assignment_id: assignment.id,
              revoked_at: nil
            ).update_all(revoked_at: now, updated_at: now)
            next unless assignment.status == "active"

            assignment.update!(status: "revoked")
            assignment.record_audit!(
              "ticketing.scanner_device_assignment.revoked",
              actor:,
              audited_changes: { reason: }
            )
          end
          device.record_audit!(
            "ticketing.scanner_device.revoked",
            actor:,
            audited_changes: { reason:, revoked_at: now }
          )
        end

        success(device)
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_device, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

      attr_reader :device, :actor, :reason
      attr_reader :idempotency_key

      def authorized?
        Events::AuthorizationResolver.organization_admin?(actor, device.organization)
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
