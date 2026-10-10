# frozen_string_literal: true

module Events
  module StaffInvitations
    class Expire < Core::BaseService
      DEFAULT_BATCH_SIZE = 500
      MAX_BATCH_SIZE = 1_000

      def initialize(event_id: nil, contact_digest: nil, limit: DEFAULT_BATCH_SIZE, at: Time.current)
        @event_id = event_id
        @contact_digest = contact_digest
        @limit = limit.to_i
        @at = at.to_time.utc
      end

      def call
        return failure(batch_error) unless valid_batch_size?

        expired_count = 0
        ActiveRecord::Base.transaction do
          due_invitations.each do |invitation|
            next unless invitation.pending? && invitation.expires_at <= at

            invitation.update!(status: "expired", expired_at: at, claim_token_ciphertext: nil)
            record_expiry!(invitation)
            expired_count += 1
          end
        end
        success(expired_count)
      rescue ActiveRecord::RecordInvalid => exception
        failure(invitation_error(exception.record))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :event_id, :contact_digest, :limit, :at

      def due_invitations
        scope = StaffInvitation.pending.where("expires_at <= ?", at)
        scope = scope.where(event_id: event_id) if event_id.present?
        scope = scope.where(contact_digest: contact_digest) if contact_digest.present?
        scope.order(:expires_at, :id).limit(limit).lock
      end

      def record_expiry!(invitation)
        audit_key = Core::KeyedDigest.digest(
          namespace: "events/staff-invitation-expiry/#{invitation.id}",
          value: invitation.expires_at.utc.iso8601(6)
        )
        result = Core::Audit::Record.call(
          audit_key:,
          action: "events.staff_invitation.expired",
          auditable_type: invitation.class.name,
          auditable_id: invitation.id,
          metadata: { invitation_id: invitation.id }
        )
        raise result.error if result.failure?
      end

      def valid_batch_size?
        limit.positive? && limit <= MAX_BATCH_SIZE
      end

      def batch_error
        Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.invitation_batch_size_invalid"),
          code: "staff_invitation_batch_size_invalid",
          status: :unprocessable_entity
        )
      end

      def invitation_error(record)
        Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.invitation_invalid"),
          code: "staff_invitation_invalid",
          status: :unprocessable_entity,
          errors: record.errors.to_hash
        )
      end
    end
  end
end
