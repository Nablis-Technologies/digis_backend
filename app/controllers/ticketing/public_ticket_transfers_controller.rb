# frozen_string_literal: true

module Ticketing
  # Public transfer landing and OTP acceptance. A random transfer token is
  # required for every action; ownership changes only after a matching OTP.
  class PublicTicketTransfersController < Ticketing::ApplicationController
    include Core::CurrentUserPreloading
    include Core::CommandResponse
    include Core::GuestRequestThrottling

    skip_before_action :authenticate_user
    skip_authorization
    before_action :set_no_store
    before_action :load_transfer
    before_action :ensure_idempotency_key_present, only: %i[request_otp accept_guest]

    def show
      return render_invalid_transfer unless valid_pending_transfer?

      render_success(data: PublicTicketTransferSerializer.new(@transfer).attributes)
    end

    def request_otp
      return render_invalid_transfer unless valid_pending_transfer?

      result = Core::PhoneVerification::Request.call(
        user: @transfer.to_user,
        phone: params.require(:phone),
        purpose: "ticket_transfer",
        idempotency_key:
      )
      return render_service_result(result) if result.failure?

      challenge = result.value
      render_success(
        data: { challenge_id: challenge.id, status: challenge.status, expires_at: challenge.expires_at },
        status: :created
      )
    rescue ActionController::ParameterMissing
      render_error(
        I18n.t("ticketing.package_workflow.errors.transfer_phone_required"),
        status: :unprocessable_entity,
        code: "transfer_phone_required"
      )
    end

    def accept_guest
      return render_invalid_transfer unless valid_transfer_token?

      result = Ticketing::Transfers::AcceptGuest.call(
        transfer: @transfer,
        token: params.require(:token),
        phone: params.require(:phone),
        verification_token: params.require(:verification_token),
        password: params[:password],
        password_confirmation: params[:password_confirmation],
        idempotency_key:,
        request:
      )
      return render_service_result(result) if result.failure?

      value = result.value
      data = {
        transfer: PublicTicketTransferSerializer.new(value.transfer).attributes,
        ticket: PublicTicketViewSerializer.new(value.ticket).attributes,
        ticket_view_url: value.ticket_view_url,
        user: value.user && Core::CurrentUserSerializer.new(preload_current_user(value.user)).attributes,
        access_token: value.access_token,
        refresh_token: value.refresh_token
      }.compact
      render_success(data:)
    rescue ActionController::ParameterMissing
      render_error(
        I18n.t("ticketing.package_workflow.errors.transfer_acceptance_failed"),
        status: :unprocessable_entity,
        code: "transfer_acceptance_failed"
      )
    end

    private

    def load_transfer
      @transfer = Ticketing::TicketTransfer.includes(
        :to_user,
        ticket: [ :event, :event_product ]
      ).find(params.require(:id))
    rescue ActiveRecord::RecordNotFound, ActionController::ParameterMissing
      render_invalid_transfer
    end

    def valid_pending_transfer?
      valid_transfer_token? && @transfer.status == "pending" && @transfer.expires_at > Time.current
    end

    def valid_transfer_token?
      return false unless @transfer

      Ticketing::TicketTransfer.token_digest_for(token: params[:token].to_s) == @transfer.token_digest
    end

    def render_invalid_transfer
      render_error(
        I18n.t("ticketing.package_workflow.errors.transfer_invalid"),
        status: :not_found,
        code: "invalid_transfer"
      )
    end

    def set_no_store
      response.set_header("Cache-Control", "no-store")
    end
  end
end
