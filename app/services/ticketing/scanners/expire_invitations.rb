# frozen_string_literal: true

module Ticketing
  module Scanners
    # Expires unused scanner capabilities in bounded batches. Pair requests
    # enforce the deadline independently, so scheduler delay cannot extend it.
    class ExpireInvitations < Core::BaseService
      DEFAULT_LIMIT = 100
      MAX_LIMIT = 500

      def initialize(at: Time.current, limit: DEFAULT_LIMIT)
        @at = at
        @limit = [ [ Integer(limit), 1 ].max, MAX_LIMIT ].min
      rescue ArgumentError, TypeError
        @limit = DEFAULT_LIMIT
      end

      def call
        expired_count = 0
        Ticketing::ScannerInvitation.transaction do
          invitations = ScannerInvitation.pairable
            .where("expires_at <= ?", at)
            .order(:expires_at, :id)
            .limit(limit)
            .lock
            .to_a
          invitations.each { |invitation| expire!(invitation) }
          expired_count = invitations.length
        end
        success(expired_count)
      rescue ActiveRecord::RecordInvalid => exception
        failure(Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.scanner_invitation_invalid"),
          code: "scanner_invitation_invalid",
          status: :unprocessable_entity,
          errors: exception.record.errors.to_hash
        ))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :at, :limit

      def expire!(invitation)
        previous_status = invitation.status
        invitation.update!(
          status: "expired",
          expired_at: at,
          token_ciphertext: nil,
          pairing_code_ciphertext: nil
        )
        invitation.record_audit!(
          "ticketing.scanner_invitation.expired",
          actor: nil,
          audit_key: "ticketing-scanner-invitation-expired-#{invitation.id}",
          audited_changes: { status: [ previous_status, "expired" ] },
          metadata: { expires_at: invitation.expires_at, delivery_revision: invitation.delivery_revision }
        )
        publish_expiry!(invitation)
      end

      def publish_expiry!(invitation)
        result = Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.scanner_invitation.expired",
          aggregate: invitation,
          payload: { invitation_id: invitation.id },
          idempotency_key: Core::KeyedDigest.digest(
            namespace: "ticketing/scanner-invitation-expired",
            value: invitation.id
          )
        )
        raise result.error if result.failure?
      end
    end
  end
end
