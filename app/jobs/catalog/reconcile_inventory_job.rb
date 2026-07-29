# frozen_string_literal: true

module Catalog
  # Runs daily at 3am. Reports held_count vs actual reservation sums.
  class ReconcileInventoryJob < ApplicationJob
    queue_as :default

    def perform
      Catalog::Inventory::Reconcile.call
    end
  end
end
