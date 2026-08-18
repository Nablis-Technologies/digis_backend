# frozen_string_literal: true

module Marketplace
  class ReconcileSellerPayoutJob < ApplicationJob
    queue_as :default

    def perform(payout_id)
      payout = Marketplace::SellerPayout.find(payout_id)
      adapter = Marketplace::PayoutProviders::Registry.fetch(payout.provider)
      Marketplace::ReconcileSellerPayout.call(payout:, adapter:)
    end
  end
end
