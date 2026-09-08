# frozen_string_literal: true

module Orders
  # Starts a provider payment for a guest order after revalidating the
  # phone-bound quote. Provider I/O and payment acceptance remain the normal
  # Orders commands, so fulfillment has one code path for guests and members.
  class GuestPaymentAttemptsController < Orders::ApplicationController
    include Core::GuestRequestThrottling

    skip_before_action :authenticate_user
    skip_authorization
    before_action :ensure_idempotency_key_present

    def create
      order = Orders::Order.includes(:event).find(params.require(:order_id))
      event = Events::Event.publicly_visible.find(order.event_id)
      payment_params = params.require(:payment_attempt).permit(
        :provider, :payment_method, :commercial_signature, :phone, :quote_token
      )
      decoded = Orders::GuestQuoteToken.decode(
        token: payment_params.fetch(:quote_token), event:, phone: payment_params.fetch(:phone)
      )
      return render_service_result(decoded) if decoded.failure?
      return render_guest_order_mismatch unless decoded.value.buyer.id == order.buyer_user_id

      result = Orders::StartPaymentAttempt.call(
        order:,
        buyer: decoded.value.buyer,
        provider: payment_params.require(:provider),
        payment_method: payment_params.require(:payment_method),
        commercial_signature: payment_params[:commercial_signature],
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Orders::PaymentSerializer }
      )
    rescue ActiveRecord::RecordNotFound
      render_error(I18n.t("errors.not_found", model: "order"), status: :not_found)
    end

    private

    def render_guest_order_mismatch
      render_error(
        I18n.t("orders.payments.errors.payment_order_not_owned"),
        status: :forbidden,
        code: "payment_order_not_owned"
      )
    end
  end
end
