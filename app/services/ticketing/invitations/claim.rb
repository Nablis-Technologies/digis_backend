# frozen_string_literal: true

module Ticketing
  module Invitations
    # Claims a pending invitation: validates the link token and marks it
    # accepted. Optionally associates the claiming user.
    class Claim < Core::BaseService
      def initialize(ticket_type:, raw_token:, user: nil)
        @ticket_type = ticket_type
        @raw_token = raw_token
        @user = user
      end

      def call
        event_id = @ticket_type.event_product.event_id
        invitation = Ticketing::Invitation.find_by(
          ticket_type_id: @ticket_type.id,
          token_digest: Ticketing::Invitation.token_digest_for(event_id:, token: @raw_token)
        )
        return failure_i18n("ticketing.invitation.errors.invalid") if invitation.blank?
        return failure_i18n("ticketing.invitation.errors.not_pending") unless invitation.status == "pending"
        return failure_i18n("ticketing.invitation.errors.expired") if invitation.expires_at.present? && invitation.expires_at <= Time.current

        ActiveRecord::Base.transaction do
          invitation.status = "accepted"
          invitation.accepted_at = Time.current
          invitation.invited_user = @user if @user.present?
          invitation.save!
        end

        success(invitation)
      rescue Core::Error => e
        failure(e)
      end
    end
  end
end
