# frozen_string_literal: true

module Finance
  # Fans one completed event out into deterministic organization/currency
  # payout-build commands. The command remains idempotent and rechecks event
  # maturity, so this job is safe to retry after an enqueue or worker crash.
  class MatureEventFundsJob < ApplicationJob
    queue_as :default

    def perform(event_id)
      event = Events::Event.find(event_id)
      return unless event.status == "completed" && event.completed_at.present?

      currencies = Finance::LedgerEntry.where(event_id: event.id).distinct.order(:currency).pluck(:currency)
      currencies.each do |currency|
        Finance::BuildPayoutsJob.perform_later(
          event.organization_id,
          currency,
          "event-maturity-#{event.id}-#{currency}"
        )
      end
    end
  end
end
