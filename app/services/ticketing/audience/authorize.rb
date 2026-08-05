# frozen_string_literal: true

module Ticketing
  module Audience
    # Read-only authorization check for a ticket type's audience gate. Does not
    # mutate access codes or invitations; the mutating consume/claim services
    # handle deduction and acceptance.
    class Authorize < Core::BaseService
      def initialize(ticket_type:, access_code: nil, invitation: nil, user: nil)
        @ticket_type = ticket_type
        @access_code = access_code
        @invitation = invitation
        @user = user
      end

      def call
        case @ticket_type.audience
        when "public"
          success(authorized: true, reason: "public")
        when "access_code"
          authorize_code
        when "invitation"
          authorize_invitation
        when "code_or_invitation"
          authorize_code_or_invitation
        else
          failure_i18n("ticketing.audience.errors.unknown_audience", audience: @ticket_type.audience)
        end
      end

      private

      def event_id
        @ticket_type.event_product.event_id
      end

      def authorize_code
        return failure_i18n("ticketing.access_code.errors.required") if @access_code.blank?

        code = Ticketing::AccessCode.find_by(
          ticket_type_id: @ticket_type.id,
          code_digest: Ticketing::AccessCode.code_digest_for(event_id:, code: @access_code)
        )
        return failure_i18n("ticketing.access_code.errors.invalid") if code.blank?
        return failure_i18n("ticketing.access_code.errors.inactive") unless code.active?
        return failure_i18n("ticketing.access_code.errors.not_yet_valid") if code.starts_at.present? && code.starts_at > Time.current
        return failure_i18n("ticketing.access_code.errors.expired") if code.expires_at.present? && code.expires_at <= Time.current
        return failure_i18n("ticketing.access_code.errors.exhausted") if code.max_uses.present? && code.used_count >= code.max_uses

        success(authorized: true, reason: "access_code", access_code: code)
      end

      def authorize_invitation
        return failure_i18n("ticketing.invitation.errors.token_required") if @invitation.blank?

        invitation = Ticketing::Invitation.find_by(
          ticket_type_id: @ticket_type.id,
          token_digest: Ticketing::Invitation.token_digest_for(event_id:, token: @invitation)
        )
        return failure_i18n("ticketing.invitation.errors.invalid") if invitation.blank?
        return failure_i18n("ticketing.invitation.errors.not_pending") unless invitation.status == "pending"
        return failure_i18n("ticketing.invitation.errors.expired") if invitation.expires_at.present? && invitation.expires_at <= Time.current

        success(authorized: true, reason: "invitation", invitation: invitation)
      end

      def authorize_code_or_invitation
        code_result = authorize_code
        return code_result if code_result.success?

        invitation_result = authorize_invitation
        return invitation_result if invitation_result.success?

        failure_i18n("ticketing.audience.errors.no_valid_code_or_invitation")
      end
    end
  end
end
