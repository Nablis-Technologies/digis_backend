# frozen_string_literal: true

module Core
  # Public OTP transport for a signed ticket view. It never returns the code or
  # raw phone; the follow-up verification returns only a short-lived proof.
  class PhoneVerificationsController < Core::ApplicationController
    include Core::GuestRequestThrottling

    skip_before_action :authenticate_user
    skip_authorization
    before_action :ensure_idempotency_key_present
    before_action :set_no_store

    def create
      ticket = ticket_for_view_token
      return render_invalid_token unless ticket

      result = Core::PhoneVerification::Request.call(
        user: ticket.owner_user,
        phone: params.require(:phone),
        purpose: "guest_claim",
        idempotency_key:
      )
      return render_service_result(result) if result.failure?

      challenge = result.value
      render_success(
        data: {
          challenge_id: challenge.id,
          status: challenge.status,
          expires_at: challenge.expires_at
        },
        status: :created
      )
    end

    def verify
      challenge = Core::PhoneVerificationChallenge.find(params.require(:id))
      result = Core::PhoneVerification::Verify.call(
        challenge:,
        code: params.require(:code)
      )
      return render_service_result(result) if result.failure?

      render_success(
        data: {
          verification_token: result.value.token,
          expires_at: 15.minutes.from_now
        }
      )
    rescue ActiveRecord::RecordNotFound
      render_error(
        I18n.t("auth.phone_verification.errors.challenge_not_found"),
        status: :not_found,
        code: "challenge_not_found"
      )
    end

    private

    def ticket_for_view_token
      raw_token = params[:token].presence || params[:ticket_view_token].presence
      return unless raw_token

      result = Ticketing::GuestTicketViewToken.verify(raw_token)
      return unless result.success?

      ticket = Ticketing::Ticket.includes(:owner_user, :event, :current_credential_generation)
        .find_by(id: result.value.ticket_id)
      return unless ticket && ticket.current_credential_generation&.version.to_i == result.value.credential_version.to_i
      return unless ticket.status == "active" && !ticket.event.cancelled?
      return unless ticket.owner_user.verified_at.blank? && ticket.owner_user.password_digest.blank?

      ticket
    end

    def render_invalid_token
      render_error(
        I18n.t("ticketing.guest_ticket.errors.invalid_view_token"),
        status: :not_found,
        code: "invalid_guest_ticket_view"
      )
    end

    def set_no_store
      response.set_header("Cache-Control", "no-store")
    end
  end
end
