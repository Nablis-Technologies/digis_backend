# frozen_string_literal: true

module Orders
  # Retries inbox processing by durable event ID. The provider payload stays
  # in the inbox row and never becomes a queue argument.
  class ProcessPaymentEventJob < ApplicationJob
    queue_as :payments
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform(payment_event_id)
      result = Orders::ProcessPaymentEvent.call(event_id: payment_event_id)
      raise result.error if result.failure?
    end
  end
end
