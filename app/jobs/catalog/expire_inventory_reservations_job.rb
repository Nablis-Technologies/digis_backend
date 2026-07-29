# frozen_string_literal: true

module Catalog
  # Runs every minute. Releases capacity for held reservations that have
  # exceeded their expiry window.
  class ExpireInventoryReservationsJob < ApplicationJob
    queue_as :default

    def perform
      Catalog::Inventory::Expire.call
    end
  end
end
