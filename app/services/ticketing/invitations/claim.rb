# frozen_string_literal: true

module Ticketing
  module Invitations
    # Claims a pending invitation: validates the link token and marks it
    # accepted. Optionally associates the claiming user.
    class Claim < Core::BaseService
      def initialize(ticket_type:, raw_token: nil, invitation: nil, user: nil, quantity: 1, at: Time.current)
        @ticket_type = ticket_type
        @raw_token = raw_token
        @invitation = invitation
        @user = user
        @quantity = quantity.to_i
        @at = at.to_time.utc
      end

      def call
        return failure_i18n("ticketing.invitation.errors.quantity_invalid") unless @quantity.positive?
        return failure_i18n("ticketing.invitation.errors.token_required") if lookup_missing?
        return failure_i18n("ticketing.invitation.errors.invalid") unless valid_lookup_mode?

        result = nil
        ActiveRecord::Base.transaction do
          invitation = invitation_for
          error_key = validation_error_key(invitation)
          result = if error_key
            failure_i18n("ticketing.invitation.errors.#{error_key}")
          else
            invitation.status = "accepted"
            invitation.accepted_at = Time.current
            invitation.invited_user = @user if @user.present? && invitation.invited_user_id.blank?
            invitation.save!
            success(invitation)
          end
        end
        result
      rescue Core::Error => e
        failure(e)
      end

      private

      def invitation_for
        scope = Ticketing::Invitation.lock.where(ticket_type_id: @ticket_type.id)
        return scope.find_by(id: @invitation.id) if @invitation.present?

        event_id = @ticket_type.event_product.event_id
        scope.find_by(token_digest: Ticketing::Invitation.token_digest_for(event_id:, token: @raw_token))
      end

      def lookup_missing?
        @raw_token.blank? && @invitation.blank?
      end

      def valid_lookup_mode?
        raw_lookup = @raw_token.is_a?(String) && @raw_token.present?
        record_lookup = @invitation.present?
        return false if raw_lookup == record_lookup
        return raw_lookup unless record_lookup

        @invitation.is_a?(Ticketing::Invitation) && @invitation.persisted?
      end

      def validation_error_key(invitation)
        return "invalid" if invitation.blank?
        return "not_pending" unless invitation.status == "pending"
        return "expired" if invitation.expires_at.present? && invitation.expires_at <= @at
        return "quantity_exceeded" if @quantity > invitation.allowed_quantity
        return "bound_to_another_user" if invitation.invited_user_id.present? && @user&.id != invitation.invited_user_id

        nil
      end
    end
  end
end
