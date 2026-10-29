# frozen_string_literal: true

require "securerandom"

module Ticketing
  module Scanners
    # Rotates a pending invitation's one-time material and publishes one
    # delivery revision. Replays never reveal old secrets or enqueue again.
    class ResendInvitation < Core::BaseService
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

        digest = request_digest(operation: "resend")
        result = nil
        ActiveRecord::Base.transaction do
          invitation.lock!
          replay = replay_command(operation: "resend", key:, digest:)
          if replay
            result = replay
            next
          end
          unless invitation.status == "pending" && invitation.expires_at > at
            result = failure(command_error(:scanner_invitation_not_resendable, :conflict))
            next
          end

          Core::Database::AdvisoryLock.acquire!("ticketing-scanner-pairing-code")
          token, code, code_digest = fresh_material
          invitation.update!(
            token:,
            token_digest: ScannerInvitation.token_digest_for(token:),
            pairing_code: code,
            pairing_code_digest: code_digest,
            pairing_code_expires_at: [ at + PAIRING_CODE_TTL, invitation.expires_at ].min,
            delivery_revision: invitation.delivery_revision + 1,
            delivery_status: "queued",
            delivery_attempts: 0,
            last_delivery_at: nil
          )
          publish_delivery!(invitation)
          record_command_audit!(
            operation: "resend",
            key:,
            digest:,
            action: "ticketing.scanner_invitation.resent",
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

      def fresh_material
        CODE_GENERATION_ATTEMPTS.times do
          code = SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
          digest = ScannerInvitation.pairing_code_digest_for(code:)
          return [ SecureRandom.hex(32), code, digest ] unless ScannerInvitation.pairable.exists?(
            pairing_code_digest: digest
          )
        end
        raise Core::Error, I18n.t("ticketing.scanner.errors.pairing_code_unavailable")
      end
    end
  end
end
