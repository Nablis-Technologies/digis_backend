# frozen_string_literal: true

module Ticketing
  # Public, offer-scoped waitlist enrollment. A supplied bearer token is
  # mandatory to validate, never silently downgraded to guest identity.
  class PublicWaitlistsController < Ticketing::ApplicationController
    include Core::GuestRequestThrottling

    skip_before_action :authenticate_user
    skip_authorization
    before_action :set_no_store
    before_action :authenticate_if_present
    before_action :ensure_idempotency_key_present

    def request_otp
      return render_error(I18n.t("ticketing.registration_workflows.errors.phone_verification_not_required"),
        status: :unprocessable_entity, code: "phone_verification_not_required") if current_user

      event, ticket_type = public_offer
      return render_not_found unless event && ticket_type

      result = Ticketing::Waitlist::RequestOtp.call(
        event:,
        ticket_type:,
        phone: waitlist_params.require(:phone),
        quantity: package_quantity,
        selected_event_date_id: waitlist_params[:selected_event_date_id],
        audience_proof:,
        idempotency_key:
      )
      return render_service_result(result) if result.failure?

      challenge = result.value.challenge
      render_success(
        data: { challenge_id: challenge.id, status: challenge.status, expires_at: challenge.expires_at },
        status: :created
      )
    rescue ActionController::ParameterMissing => error
      render_invalid_request(error)
    end

    def create
      event, ticket_type = public_offer
      return render_not_found unless event && ticket_type

      result = Ticketing::Waitlist::Submit.call(
        event:,
        ticket_type:,
        actor: current_user,
        guest: current_user.nil?,
        phone: waitlist_params[:phone],
        verification_token: waitlist_params[:verification_token],
        email: waitlist_params[:email],
        full_name: waitlist_params[:full_name],
        submission: registration_submission,
        audience_proof:,
        idempotency_key:
      )
      return render_service_result(result) if result.failure?

      outcome = result.value
      render_success(
        data: {
          registration: outcome.registration,
          next_action: { type: outcome.next_action }
        },
        status: :created,
        serializer_options: { registration: { serializer: Ticketing::RegistrationSerializer } }
      )
    rescue ActionController::ParameterMissing => error
      render_invalid_request(error)
    end

    private

    def waitlist_params
      @waitlist_params ||= params.require(:waitlist)
    end

    def public_offer
      event = Events::Event.publicly_visible.find_by(slug: params[:event_slug])
      return [ nil, nil ] unless event

      product = Catalog::EventProduct.where(event_id: event.id, id: params[:event_product_id], type: "ticket")
        .includes(:ticket_type, :prices, :inventories, product_accesses: :event_date)
        .find_by(status: "active")
      [ event, product&.ticket_type ]
    end

    def registration_submission
      Ticketing::RegistrationSubmission.new(
        package_quantity: package_quantity,
        selected_event_date_id: waitlist_params[:selected_event_date_id],
        answers: Ticketing::RegistrationSubmission.normalize_entries(
          waitlist_params[:answers], permitted_fields: Ticketing::RegistrationSubmission::ANSWER_FIELDS
        ),
        consents: Ticketing::RegistrationSubmission.normalize_entries(
          waitlist_params[:consents], permitted_fields: Ticketing::RegistrationSubmission::CONSENT_FIELDS
        )
      )
    end

    def package_quantity
      value = waitlist_params[:quantity].presence || 1
      return value if value.is_a?(Integer)
      return value.to_i if value.to_s.match?(/\A[1-9]\d*\z/)

      value
    end

    def audience_proof
      {
        access_code: waitlist_params[:access_code],
        invitation: waitlist_params[:invitation_token]
      }
    end

    def authenticate_if_present
      return if request.headers["Authorization"].blank?

      authenticate_user
    end

    def set_no_store
      response.set_header("Cache-Control", "no-store")
    end

    def render_not_found
      render_error(
        I18n.t("ticketing.registration_workflows.errors.waitlist_product_not_found"),
        status: :not_found,
        code: "waitlist_product_not_found"
      )
    end

    def render_invalid_request(error)
      render_error(
        I18n.t("errors.parameter_missing", param: error.param),
        status: :bad_request,
        code: "invalid_request"
      )
    end
  end
end
