# frozen_string_literal: true

module Finance
  class DispatchPayoutJob < ApplicationJob
    queue_as :default

    def perform(payout_id)
      payout = Finance::Payout.find(payout_id)
      adapter = Finance::PayoutProviders::Registry.fetch(payout.provider)
      Finance::DispatchPayout.call(payout:, adapter:)
    end
  end
end
