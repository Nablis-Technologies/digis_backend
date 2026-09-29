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
      Events::Event.publicly_visible.find(order.event_id)
      payment_params = params.require(:payment_attempt).permit(
        :provider, :payment_method, :commercial_signature, :phone, :quote_token, :order_access_token
      )
      access = Orders::ResolveGuestOrderAccess.call(
        order:,
        phone: payment_params.require(:phone),
        quote_token: payment_params[:quote_token],
        order_access_token: payment_params[:order_access_token]
      )
      return render_service_result(access) if access.failure?

      result = Orders::StartPaymentAttempt.call(
        order:,
        buyer: access.value,
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
  end
end
