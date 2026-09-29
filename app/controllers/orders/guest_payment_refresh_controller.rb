# frozen_string_literal: true

module Orders
  # Guest-safe payment confirmation. The quote token and phone bind the
  # request to the shadow buyer; PaymentRefresh still owns provider checking
  # and the normal wallet projection.
  class GuestPaymentRefreshController < Orders::ApplicationController
    include Core::GuestRequestThrottling

    skip_before_action :authenticate_user
    skip_authorization
    before_action :ensure_idempotency_key_present
    before_action :set_no_store

    def create
      payment = Orders::Payment.includes(order: :event).find(params.require(:payment_id))
      Events::Event.publicly_visible.find(payment.order.event_id)
      refresh_params = params.require(:payment_refresh).permit(:phone, :quote_token, :order_access_token)
      access = Orders::ResolveGuestOrderAccess.call(
        order: payment.order,
        phone: refresh_params.require(:phone),
        quote_token: refresh_params[:quote_token],
        order_access_token: refresh_params[:order_access_token]
      )
      return render_service_result(access) if access.failure?

      result = Orders::PaymentRefresh.call(
        payment:, buyer: access.value, idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: {
          payment: { serializer: Orders::PaymentSerializer },
          order: { serializer: Orders::OrderSerializer },
          tickets: { serializer: Ticketing::GuestPaymentTicketSerializer }
        }
      )
    rescue ActiveRecord::RecordNotFound
      render_error(I18n.t("errors.not_found", model: "payment"), status: :not_found)
    end

    private

    def set_no_store
      response.set_header("Cache-Control", "no-store")
    end
  end
end
