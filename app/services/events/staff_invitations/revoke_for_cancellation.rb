# frozen_string_literal: true

module Events
  module StaffInvitations
    class RevokeForCancellation < Core::BaseService
      BATCH_SIZE = 500

      def initialize(event:, actor:, at: Time.current)
        @event = event
        @actor = actor
        @at = at.to_time.utc
      end

      def call
        revoked_count = 0
        Events::Event.transaction do
          event.lock!
          loop do
            batch = event.staff_invitations.pending.order(:id).limit(BATCH_SIZE).lock.to_a
            break if batch.empty?

            batch.each do |invitation|
              revoke!(invitation)
              revoked_count += 1
            end
            break if batch.length < BATCH_SIZE
          end
        end
        success(revoked_count)
      rescue ActiveRecord::RecordInvalid => exception
        failure(Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.invitation_invalid"),
          code: "staff_invitation_invalid",
          status: :unprocessable_entity,
          errors: exception.record.errors.to_hash
        ))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :event, :actor, :at

      def revoke!(invitation)
        invitation.update!(status: "revoked", revoked_at: at, claim_token_ciphertext: nil)
        invitation.record_audit!(
          "events.staff_invitation.revoked_for_cancellation",
          actor:,
          audit_key: audit_key(invitation),
          audited_changes: { status: [ "pending", "revoked" ] },
          metadata: {
            invitation_id: invitation.id,
            event_id: event.id,
            reason: "event_cancelled"
          }
        )
      end

      def audit_key(invitation)
        Core::KeyedDigest.digest(
          namespace: "events/staff-invitation-cancellation-revocation/#{invitation.id}",
          value: event.id
        )
      end
    end
  end
end
