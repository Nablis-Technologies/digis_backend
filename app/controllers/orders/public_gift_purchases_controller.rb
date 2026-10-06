# frozen_string_literal: true

module Orders
  # Public recipient surface for a bearer gift link. The token is accepted only
  # in the JSON body and every response is private and non-cacheable.
  class PublicGiftPurchasesController < Orders::ApplicationController
    include Core::GuestRequestThrottling

    skip_before_action :authenticate_user
    skip_authorization
    before_action :set_no_store
    before_action :authenticate_if_present
    before_action :ensure_idempotency_key_present, only: :claim

    def resolve
      result = Orders::GiftPurchases::Resolve.call(
        gift_purchase_id: params[:id],
        token: gift_params.require(:token),
        actor: current_user
      )
      return render_service_result(result) if result.failure?

      render_success(data: result.value.to_h)
    rescue ActionController::ParameterMissing => exception
      render_invalid_request(exception)
    end

    def claim
      submission = registration_submission
      return render_invalid_selection unless submission

      result = Orders::GiftPurchases::Claim.call(
        gift_purchase_id: params[:id],
        token: gift_params.require(:token),
        actor: current_user,
        submission:,
        idempotency_key:
      )
      return render_service_result(result) if result.failure?

      resolved = Orders::GiftPurchases::Resolve.call(
        gift_purchase_id: params[:id],
        token: gift_params.require(:token),
        actor: current_user
      )
      return render_service_result(resolved) if resolved.failure?

      render_success(data: resolved.value.to_h)
    rescue ActionController::ParameterMissing => exception
      render_invalid_request(exception)
    rescue Orders::AdmissionSelectionEnvelope::InvalidInput
      render_invalid_selection
    end

    private

    def gift_params
      @gift_params ||= ActionController::Parameters.new(request.request_parameters).require(:gift)
    end

    def registration_submission
      answers = Ticketing::RegistrationSubmission.normalize_entries(
        gift_params[:answers],
        permitted_fields: Ticketing::RegistrationSubmission::ANSWER_FIELDS
      )
      consents = Ticketing::RegistrationSubmission.normalize_entries(
        gift_params[:consents],
        permitted_fields: Ticketing::RegistrationSubmission::CONSENT_FIELDS
      )
      return if answers.nil? || consents.nil?

      Ticketing::RegistrationSubmission.new(
        package_quantity: 1,
        selected_event_date_id: nil,
        answers:,
        consents:
      )
    end

    def authenticate_if_present
      return if request.headers["Authorization"].blank?

      authenticate_user
    end

    def set_no_store
      response.set_header("Cache-Control", "no-store")
    end

    def render_invalid_request(exception)
      render_error(
        I18n.t("errors.parameter_missing", param: exception.param),
        status: :bad_request,
        code: "invalid_request"
      )
    end

    def render_invalid_selection
      render_error(
        I18n.t("orders.gift_purchases.errors.gift_claim_invalid"),
        status: :unprocessable_entity,
        code: "gift_claim_invalid"
      )
    end
  end
end
