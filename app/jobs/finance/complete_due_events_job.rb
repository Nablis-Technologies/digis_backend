# frozen_string_literal: true

module Finance
  # Runs the automatic event-completion sweep. The command owns all locking,
  # idempotency, audit, and maturity fan-out behavior for each candidate.
  class CompleteDueEventsJob < ApplicationJob
    queue_as :default

    def perform
      Finance::CompleteDueEvents.call(at: Time.current)
    end
  end
end
