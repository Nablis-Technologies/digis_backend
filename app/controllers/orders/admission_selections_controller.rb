# frozen_string_literal: true

module Orders
  # Public write boundary for ticket selection. Authentication is optional,
  # but a supplied bearer token must authenticate successfully.
  class AdmissionSelectionsController < Orders::ApplicationController
    include Core::GuestRequestThrottling

    skip_before_action :authenticate_user
    skip_authorization
    before_action :set_no_store
    before_action :authenticate_if_present
    before_action :ensure_idempotency_key_present

    def request_otp
      event = public_event
      return render_not_found unless event

      result = Orders::AdmissionSelections::RequestOtp.call(
        event:,
        items: normalized_items,
        charge_currency: selection_params[:charge_currency],
        phone: selection_params.require(:phone),
        promotion_code: selection_params[:promotion_code],
        idempotency_key:
      )
      return render_service_result(result) if result.failure?

      challenge = result.value.challenge
      render_success(
        data: {
          challenge_id: challenge.id,
          status: challenge.status,
          expires_at: challenge.expires_at
        },
        status: :created
      )
    rescue ActionController::ParameterMissing => error
      render_invalid_request(error)
    rescue Orders::AdmissionSelectionEnvelope::InvalidInput
      render_invalid_selection
    end

    def create
      event = public_event
      return render_not_found unless event

      result = Orders::AdmissionSelections::Create.call(
        event:,
        buyer: current_user,
        idempotency_key:,
        selection: {
          items: normalized_items,
          charge_currency: selection_params[:charge_currency],
          promotion_code: selection_params[:promotion_code],
          guest: current_user.nil?,
          phone: selection_params[:phone],
          phone_confirmation: boolean_param(selection_params[:phone_confirmation]),
          verification_token: selection_params[:verification_token],
          email: selection_params[:email],
          full_name: selection_params[:full_name]
        }
      )
      return render_service_result(result) if result.failure?

      outcome = result.value
      action = next_action_for(outcome)
      data = {
        order: outcome.order,
        registration: outcome.registration,
        registrations: outcome.registrations.map { |registration| registration_summary(registration) },
        next_action: action
      }
      data[:guest_order_token] = outcome.guest_order_token if outcome.guest_order_token.present?
      render_success(
        data:,
        status: :created,
        serializer_options: {
          order: { serializer: Orders::OrderSerializer },
          registration: { serializer: Ticketing::RegistrationSerializer },
          registrations: nil
        }
      )
    rescue ActionController::ParameterMissing => error
      render_invalid_request(error)
    rescue Orders::AdmissionSelectionEnvelope::InvalidInput
      render_invalid_selection
    end

    private

    def selection_params
      @selection_params ||= params.require(:admission_selection)
    end

    def normalized_items
      Orders::AdmissionSelectionEnvelope.new(
        items: selection_params[:items],
        public_payload: true
      ).items
    end

    def public_event
      Events::Event.publicly_visible.find_by(slug: params[:event_slug])
    end

    def authenticate_if_present
      return if request.headers["Authorization"].blank?

      authenticate_user
    end

    def boolean_param(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def set_no_store
      response.set_header("Cache-Control", "no-store")
    end

    def next_action_for(outcome)
      action = { type: outcome.next_action }
      if outcome.order
        action.merge!(
          order_id: outcome.order.id,
          charge_currency: outcome.order.charge_currency,
          amount_minor: outcome.order.total_minor,
          expires_at: outcome.order.expires_at
        )
      elsif outcome.registration
        action[:registration_id] = outcome.registration.id
      elsif outcome.next_action == "waitlist_available"
        action[:event_product_ids] = outcome.waitlist_product_ids
      end
      action
    end

    def registration_summary(registration)
      {
        id: registration.id,
        status: registration.status,
        next_action: Ticketing::RegistrationNextAction.for(registration).type
      }
    end

    def render_not_found
      render_error(
        I18n.t("errors.not_found", model: "event"),
        status: :not_found,
        code: "event_not_found"
      )
    end

    def render_invalid_request(error)
      render_error(
        I18n.t("errors.parameter_missing", param: error.param),
        status: :bad_request,
        code: "invalid_request"
      )
    end

    def render_invalid_selection
      render_error(
        I18n.t("orders.checkout.errors.admission_selection_invalid"),
        status: :unprocessable_entity,
        code: "admission_selection_invalid"
      )
    end
  end
end
