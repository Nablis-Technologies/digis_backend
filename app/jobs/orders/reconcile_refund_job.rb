# frozen_string_literal: true

module Orders
  # Verifies one ambiguous provider refund. It carries only the durable refund
  # ID so retries cannot accidentally replay a provider refund request.
  class ReconcileRefundJob < ApplicationJob
    queue_as :payments
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform(refund_id)
      result = Orders::ReconcileRefund.call(refund: Orders::Refund.find(refund_id))
      raise result.error if result.failure?
    end
  end
end
