# frozen_string_literal: true

module Orders
  # Runs the final bounded settlement decision for one durable payment ID.
  class ExpireSettlementGraceJob < ApplicationJob
    queue_as :payments
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform(payment_id)
      result = Orders::ExpireSettlementGrace.call(payment_id:)
      raise result.error if result.failure?
    end
  end
end
