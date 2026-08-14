# frozen_string_literal: true

module Marketplace
  # Runs the durable resale-hold deadline. The service rechecks the listing
  # under its lock so a sold listing or a replayed job is harmless.
  class ExpireReservationJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform(listing_id)
      result = Marketplace::ExpireReservation.call(listing: Marketplace::ResaleListing.find(listing_id))
      raise result.error if result.failure?
    end
  end
end
