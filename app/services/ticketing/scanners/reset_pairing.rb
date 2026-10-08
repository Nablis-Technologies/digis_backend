# frozen_string_literal: true

require "securerandom"

module Ticketing
  module Scanners
    # Revokes a lost scanner session/device binding and issues a fresh
    # capability while preserving the event-owned staff assignment.
    class ResetPairing < Core::BaseService
      include InvitationCommandSupport

      PAIRING_CODE_TTL = 10.minutes
      CODE_GENERATION_ATTEMPTS = 10

      def initialize(invitation:, actor:, idempotency_key:, at: Time.current)
        @invitation = invitation
        @actor = actor
        @idempotency_key_input = idempotency_key
        @at = at
      end

      def call
        key = command_key
        return failure(command_error(:invalid_idempotency_key, :bad_request)) unless key
        return failure(command_error(:invitation_forbidden, :forbidden)) unless authorized?

        digest = request_digest(operation: "reset_pairing")
        result = nil
        ActiveRecord::Base.transaction do
          invitation.lock!
          replay = replay_command(operation: "reset_pairing", key:, digest:)
          if replay
            result = replay
            next
          end

          staff_assignment_active = Events::EventStaffAssignment.active.exists?(
            id: invitation.event_staff_assignment_id,
            event_id: invitation.event_id,
            role: "scanner"
          )
          unless invitation.status.in?(%w[paired pairing_reset]) && invitation.expires_at > at &&
              staff_assignment_active
            result = failure(command_error(:scanner_invitation_not_resettable, :conflict))
            next
          end

          revoke_current_pairing!
          Core::Database::AdvisoryLock.acquire!("ticketing-scanner-pairing-code")
          token, code, code_digest = fresh_material
          invitation.update!(
            status: "pairing_reset",
            token:,
            token_digest: ScannerInvitation.token_digest_for(token:),
            pairing_code: code,
            pairing_code_digest: code_digest,
            pairing_code_expires_at: [ at + PAIRING_CODE_TTL, invitation.expires_at ].min,
            pairing_method: nil,
            paired_at: nil,
            delivery_revision: invitation.delivery_revision + 1,
            delivery_status: "queued",
            delivery_attempts: 0,
            last_delivery_at: nil
          )
          publish_delivery!(invitation)
          record_command_audit!(
            operation: "reset_pairing",
            key:,
            digest:,
            action: "ticketing.scanner_invitation.pairing_reset",
            metadata: { delivery_revision: invitation.delivery_revision }
          )
          result = success(Result.new(record: invitation, token:, pairing_code: code, replayed: false))
        end
        result
      rescue ActiveRecord::RecordInvalid => exception
        failure(command_error(:scanner_invitation_invalid, :unprocessable_entity,
                              errors: exception.record.errors.to_hash))
      rescue Core::Audit::Record::ReplayConflict
        failure(command_error(:idempotency_conflict, :conflict))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :invitation, :actor, :idempotency_key_input, :at

      def authorized?
        Events::AuthorizationResolver.can_assign?(actor, invitation.event, "scanner")
      end

      def revoke_current_pairing!
        now = at
        ScannerSession.where(scanner_invitation_id: invitation.id, revoked_at: nil)
                      .update_all(revoked_at: now, updated_at: now)
        assignment = Ticketing::ScannerDeviceAssignment.find_by(
          id: invitation.scanner_device_assignment_id,
          status: "active"
        )
        return unless assignment

        assignment.lock!
        assignment.update!(status: "revoked")
        assignment.record_audit!(
          "ticketing.scanner_device_assignment.revoked",
          actor:,
          audited_changes: { reason: "pairing_reset" }
        )
      end

      def fresh_material
        CODE_GENERATION_ATTEMPTS.times do
          code = SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
          code_digest = ScannerInvitation.pairing_code_digest_for(code:)
          return [ SecureRandom.hex(32), code, code_digest ] unless ScannerInvitation.pairable.exists?(
            pairing_code_digest: code_digest
          )
        end
        raise Core::Error, I18n.t("ticketing.scanner.errors.pairing_code_unavailable")
      end
    end
  end
end
