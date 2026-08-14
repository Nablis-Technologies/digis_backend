# frozen_string_literal: true

module Marketplace
  class BuildSellerPayoutJob < ApplicationJob
    queue_as :default

    def perform(seller_user_id, account_id, event_id, currency, idempotency_key)
      result = Marketplace::BuildSellerPayout.call(
        seller: Core::User.find(seller_user_id),
        account: Marketplace::SellerPayoutAccount.find(account_id),
        event: Events::Event.find(event_id),
        currency:,
        idempotency_key:
      )
      Marketplace::DispatchSellerPayoutJob.perform_later(result.value.id) if result.success?
    end
  end
end
