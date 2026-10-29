# frozen_string_literal: true

module Orders
  # Unauthenticated provider redirect endpoint. The callback is never trusted
  # as payment proof; RecordPaymentCallback verifies the transaction first.
  class PaymentCallbacksController < Orders::ApplicationController
    skip_before_action :authenticate_user
    skip_authorization only: :show

    def show
      result = Orders::RecordPaymentCallback.call(
        provider: params[:provider],
        transaction_reference: params[:merchant_reference] || params[:trx_ref] || params[:tx_ref],
        provider_reference: params[:chapa_reference] || params[:ref_id] || params[:reference],
        callback_status: params[:status]
      )
      return render_service_result(result) if result.failure?

      event = result.value
      render_success(
        I18n.t("orders.payments.callbacks.received"),
        data: { payment_event_id: event.id, payment_id: event.payment_id, status: event.status },
        status: :accepted
      )
    end
  end
end
