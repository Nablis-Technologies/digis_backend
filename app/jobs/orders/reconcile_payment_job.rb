# frozen_string_literal: true

module Orders
  # Submits a durable refund obligation after the acceptance transaction has
  # committed. Provider calls happen without aggregate locks; the refund row
  # and provider idempotency key make retries safe.
  class ReconcilePaymentJob < ApplicationJob
    queue_as :payments
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform(refund_id)
      refund = Orders::Refund.includes(:payment).find(refund_id)
      return if refund.succeeded?

      refund.update!(status: "processing") if refund.status == "created"
      adapter = Payments::Providers::Registry.fetch(refund.payment.provider)
      result = adapter.refund(
        payment_id: refund.payment_id,
        provider_reference: refund.payment.provider_reference,
        amount_minor: refund.amount_minor,
        currency: refund.currency,
        idempotency_key: refund.idempotency_key
      )
      normalized = result.is_a?(Payments::Providers::Result) ? result : Payments::Providers::Result.from_provider_response(result)
      persist_result(refund.id, normalized)
    end

    private

    def persist_result(refund_id, result)
      refund = Orders::Refund.lock.find(refund_id)
      case result.status
      when "success"
        refund.update!(
          status: "succeeded",
          provider_reference: result.provider_reference,
          provider_fee_minor: result.provider_fee_minor,
          provider_fee_currency: result.provider_fee_currency,
          provider_fee_recorded_at: result.provider_fee_minor.present? ? Time.current : nil,
          pending_reason: nil,
          next_retry_at: nil
        )
      when "failure"
        refund.update!(status: "failed", pending_reason: result.failure_code, next_retry_at: nil)
      else
        refund.update!(status: "processing", pending_reason: "provider_processing", next_retry_at: 5.minutes.from_now)
      end
    end
  end
end
