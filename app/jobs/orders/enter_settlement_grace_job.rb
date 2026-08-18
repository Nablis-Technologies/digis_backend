# frozen_string_literal: true

module Orders
  # Periodically finds buyer deadlines that have passed and enters only
  # eligible current payment attempts into bounded settlement grace.
  class EnterSettlementGraceJob < ApplicationJob
    queue_as :payments
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform
      result = Orders::ExpireCheckout.call
      raise result.error if result.failure?
    end
  end
end
