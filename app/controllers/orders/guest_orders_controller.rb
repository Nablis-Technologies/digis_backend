# frozen_string_literal: true

module Orders
  # Creates an order from a phone-bound guest quote. The quote token and phone
  # are both required so an order ID alone cannot be used as guest authority.
  class GuestOrdersController < Orders::ApplicationController
    include Core::GuestRequestThrottling

    skip_before_action :authenticate_user
    skip_authorization
    before_action :ensure_idempotency_key_present

    def create
      event_id = params[:event_id].presence || order_params[:event_id].presence
      return render_error(I18n.t("orders.checkout.errors.event_required"), status: :bad_request, code: "event_required") unless event_id

      event = Events::Event.publicly_visible.find(event_id)
      decoded = Orders::GuestQuoteToken.decode(
        token: order_params.fetch(:quote_token), event:, phone: order_params.fetch(:phone)
      )
      return render_service_result(decoded) if decoded.failure?

      result = Orders::GuestCheckout.call(
        quote: decoded.value.quote,
        event:,
        buyer: decoded.value.buyer,
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Orders::OrderSerializer }
      )
    rescue ActiveRecord::RecordNotFound
      render_error(I18n.t("errors.not_found", model: "event"), status: :not_found)
    end

    private

    def order_params
      params.require(:order).permit(:event_id, :quote_token, :phone)
    end
  end
end
