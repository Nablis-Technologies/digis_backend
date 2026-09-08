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
      event = Events::Event.publicly_visible.find(payment.order.event_id)
      refresh_params = params.require(:payment_refresh).permit(:phone, :quote_token)
      decoded = Orders::GuestQuoteToken.decode(
        token: refresh_params.fetch(:quote_token), event:, phone: refresh_params.fetch(:phone)
      )
      return render_service_result(decoded) if decoded.failure?
      return render_guest_order_mismatch unless decoded.value.buyer.id == payment.order.buyer_user_id

      result = Orders::PaymentRefresh.call(
        payment:, buyer: decoded.value.buyer, idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: {
          payment: { serializer: Orders::PaymentSerializer },
          order: { serializer: Orders::OrderSerializer },
          tickets: { serializer: Ticketing::TicketWalletSerializer }
        }
      )
    rescue ActiveRecord::RecordNotFound
      render_error(I18n.t("errors.not_found", model: "payment"), status: :not_found)
    end

    private

    def render_guest_order_mismatch
      render_error(
        I18n.t("orders.payments.errors.payment_order_not_owned"),
        status: :forbidden,
        code: "payment_order_not_owned"
      )
    end

    def set_no_store
      response.set_header("Cache-Control", "no-store")
    end
  end
end
