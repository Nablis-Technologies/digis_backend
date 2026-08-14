# frozen_string_literal: true

module Commercial
  # Runs append-only Commercial/Finance reconciliation. Failed results are
  # raised so the recurring job backend retries transient database or outbox
  # failures instead of silently losing an operational observation.
  class ReconciliationJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(at: Time.current)
      result = Commercial::Reconciliation::Run.call(at:)
      raise result.error if result.failure?

      result.value
    end
  end
end
