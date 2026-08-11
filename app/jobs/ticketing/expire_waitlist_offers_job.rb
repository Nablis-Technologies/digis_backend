# frozen_string_literal: true

module Ticketing
  # Reclaims expired offer holds through the same command used by manual expiry,
  # preserving the queue timestamp and idempotent audit boundary.
  class ExpireWaitlistOffersJob < ApplicationJob
    queue_as :default

    def perform
      Ticketing::Registration
        .where(status: "offered")
        .where("offer_expires_at <= ?", Time.current)
        .find_each do |registration|
          Ticketing::Waitlist::ExpireOffer.call(
            registration:,
            idempotency_key: "ticketing-waitlist-expire-#{registration.id}-#{registration.offer_expires_at.to_i}"
          )
        end
    end
  end
end
