# frozen_string_literal: true

module Ticketing
  # Expires pending package transfers after their acceptance window. Ownership
  # and the current generation remain unchanged because expiry is pre-acceptance.
  class ExpireTransfersJob < ApplicationJob
    queue_as :default

    def perform
      Ticketing::TicketTransfer
        .where(status: "pending")
        .where("expires_at <= ?", Time.current)
        .update_all(status: "expired", updated_at: Time.current)
    end
  end
end
