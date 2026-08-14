# frozen_string_literal: true

module Marketplace
  # Fans out one deterministic payout-build command per seller/event/currency
  # once the ledger's immutable availability time is reached. Sellers without
  # a verified destination remain pending and are intentionally not paid by a
  # primary purchase method.
  class MatureSellerProceedsJob < ApplicationJob
    queue_as :default

    def perform(event_id, at: Time.current)
      SellerLedgerEntry
        .where(event_id:, type: %w[resale_proceeds cancellation_reversal chargeback adjustment])
        .where("available_at <= ?", at)
        .distinct
        .pluck(:seller_user_id, :currency)
        .each do |seller_user_id, currency|
          account = SellerPayoutAccount.where(user_id: seller_user_id, status: "verified")
            .order(verified_at: :desc, id: :desc).first
          next unless account

          BuildSellerPayoutJob.perform_later(
            seller_user_id,
            account.id,
            event_id,
            currency,
            "marketplace-seller-payout-matured-#{event_id}-#{seller_user_id}-#{currency}"
          )
        end
    end
  end
end
