# frozen_string_literal: true

module Orders
  # Buyer-facing payment-attempt command surface. Authorization stays on the
  # order aggregate; the command owns idempotency, locking, provider I/O, and
  # the rule that ambiguous provider outcomes remain processing.
  class PaymentAttemptsController < Orders::ApplicationController
    before_action :ensure_idempotency_key_present

    def create
      order = Orders::Order.find(params.require(:order_id))
      authorize order, :start_payment_attempt?

      result = Orders::StartPaymentAttempt.call(
        order:,
        buyer: current_user,
        provider: payment_attempt_params.require(:provider),
        payment_method: payment_attempt_params.require(:payment_method),
        commercial_signature: payment_attempt_params[:commercial_signature],
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Orders::PaymentSerializer }
      )
    end

    private

    def payment_attempt_params
      params.require(:payment_attempt).permit(:provider, :payment_method, :commercial_signature)
    end
  end
end
