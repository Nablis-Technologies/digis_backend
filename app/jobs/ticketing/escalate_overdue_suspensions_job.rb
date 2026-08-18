# frozen_string_literal: true

module Ticketing
  # Resolves overdue reviews as an explicit support escalation. It deliberately
  # leaves the package suspended; no deadline job is allowed to restore access
  # or invent refund evidence on behalf of a later financial workflow.
  class EscalateOverdueSuspensionsJob < ApplicationJob
    queue_as :default

    def perform
      Ticketing::TicketSuspension
        .includes(:initiated_by)
        .overdue
        .find_each(batch_size: 100) do |suspension|
        result = Ticketing::Suspensions::Resolve.call(
          suspension:,
          actor: suspension.initiated_by,
          resolution: "expired",
          resolution_reason: "review_deadline_expired",
          idempotency_key: "ticketing-suspension-expiry-#{suspension.id}"
        )
        Rails.logger.warn("Ticket suspension escalation failed: #{result.error.code}") if result.failure?
      end
    end
  end
end
