# frozen_string_literal: true

module Finance
  class ReconcilePayoutJob < ApplicationJob
    queue_as :default

    def perform(payout_id)
      payout = Finance::Payout.find(payout_id)
      adapter = Finance::PayoutProviders::Registry.fetch(payout.provider)
      Finance::ReconcilePayout.call(payout:, adapter:)
    end
  end
end
