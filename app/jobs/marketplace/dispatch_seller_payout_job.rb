# frozen_string_literal: true

module Marketplace
  class DispatchSellerPayoutJob < ApplicationJob
    queue_as :default

    def perform(payout_id)
      payout = Marketplace::SellerPayout.find(payout_id)
      adapter = Marketplace::PayoutProviders::Registry.fetch(payout.provider)
      Marketplace::DispatchSellerPayout.call(payout:, adapter:)
    end
  end
end
