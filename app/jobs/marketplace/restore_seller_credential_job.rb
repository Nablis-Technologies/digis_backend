# frozen_string_literal: true

module Marketplace
  # Replays seller credential recovery after an operational retry. Recovery is
  # idempotent and never reactivates the revoked generation.
  class RestoreSellerCredentialJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform(listing_id)
      result = Marketplace::RestoreSellerAccess.call(
        listing: Marketplace::ResaleListing.find(listing_id)
      )
      raise result.error if result.failure?
    end
  end
end
