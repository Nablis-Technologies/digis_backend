# frozen_string_literal: true

module Orders
  # Public guest quote preview. The phone-confirmation acknowledgement is
  # required before a shadow identity is created or a quote token is issued.
  class GuestOrderQuotesController < Orders::ApplicationController
    include Core::GuestRequestThrottling

    skip_before_action :authenticate_user
    skip_authorization

    def create
      event = Events::Event.publicly_visible.find(params.require(:event_id))
      return render_invalid_phone_confirmation unless phone_confirmed?

      promotion_result = Orders::PromotionContext.call(event:, raw_code: params[:promotion_code])
      return render_service_result(promotion_result) if promotion_result.failure?

      identity = Core::PhoneIdentity::ResolveOrCreate.call(
        phone: params.require(:phone), actor: nil, allow_actor_mismatch: true
      )
      return render_service_result(identity) if identity.failure?
      return render_guest_authentication_required unless shadow_user?(identity.value.user)

      result = Orders::BuildQuote.call(
        event:,
        buyer: identity.value.user,
        items: item_requests,
        charge_currency: params.require(:charge_currency),
        provider: params[:provider],
        payment_method: params[:payment_method],
        promotion: promotion_result.value.promotion,
        promotion_code: params[:promotion_code]
      )
      return render_service_result(result) if result.failure?

      token = Orders::GuestQuoteToken.issue(
        quote: result.value, event:, buyer: identity.value.user, phone: params[:phone]
      )
      data = Orders::QuoteSerializer.new(result.value, quote_token: token).attributes.symbolize_keys
      render_success(data:)
    rescue ActiveRecord::RecordNotFound
      render_error(I18n.t("errors.not_found", model: "event"), status: :not_found)
    end

    private

    def item_requests
      Array(params[:items]).map do |item|
        attributes = item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h : item
        attributes = attributes.to_h.symbolize_keys
        attributes.slice(
          :event_product_id, :quantity, :registration_id, :event_date_ids, :venue_event_date_ids
        ).merge(product_id: attributes[:event_product_id])
      end
    end

    def phone_confirmed?
      params[:phone_confirmation] == true || params[:phone_confirmation].to_s == "true"
    end

    def shadow_user?(user)
      user.verified_at.blank? && user.password_digest.blank?
    end

    def render_invalid_phone_confirmation
      render_error(
        I18n.t("ticketing.registrations.errors.phone_confirmation_required"),
        status: :bad_request,
        code: "phone_confirmation_required"
      )
    end

    def render_guest_authentication_required
      render_error(
        I18n.t("ticketing.registrations.errors.guest_requires_authentication"),
        status: :conflict,
        code: "guest_requires_authentication"
      )
    end
  end
end
