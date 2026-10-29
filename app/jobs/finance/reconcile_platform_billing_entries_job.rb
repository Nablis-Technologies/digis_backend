# frozen_string_literal: true

module Finance
  class ReconcilePlatformBillingEntriesJob < ApplicationJob
    queue_as :maintenance

    def perform(limit = Finance::ReconcilePlatformBillingEntries::DEFAULT_LIMIT)
      result = Finance::ReconcilePlatformBillingEntries.call(limit:)
      raise result.error if result.failure?
    end
  end
end
