# frozen_string_literal: true

module Ticketing
  module Scanners
    # Revokes an unclaimed scanner invitation without deleting its audit history.
    class RevokeInvitation < Core::BaseService
      include InvitationCommandSupport

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

        digest = request_digest(operation: "revoke")
        result = nil
        ActiveRecord::Base.transaction do
          invitation.lock!
          replay = replay_command(operation: "revoke", key:, digest:)
          if replay
            result = replay
            next
          end
          unless invitation.status.in?(%w[pending pairing_reset])
            result = failure(command_error(:scanner_invitation_not_revocable, :conflict))
            next
          end

          invitation.update!(
            status: "revoked",
            revoked_at: at,
            token_ciphertext: nil,
            pairing_code_ciphertext: nil
          )
          record_command_audit!(
            operation: "revoke",
            key:,
            digest:,
            action: "ticketing.scanner_invitation.revoked"
          )
          result = success(Result.new(record: invitation, token: nil, pairing_code: nil, replayed: false))
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
    end
  end
end
