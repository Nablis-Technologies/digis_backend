# frozen_string_literal: true

module Orders
  # Delivers one committed refund obligation to the provider boundary. The
  # command owns state and idempotency; the job only carries the durable ID.
  class SubmitRefundJob < ApplicationJob
    queue_as :payments
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform(refund_id)
      result = Orders::SubmitRefund.call(refund: Orders::Refund.find(refund_id))
      raise result.error if result.failure?
    end
  end
end
