# frozen_string_literal: true

require "test_helper"

module Catalog
  class ReconcileInventoryJobTest < ActiveJob::TestCase
    test "performs reconciliation without error" do
      event = events_events(:ready_listing)
        product = Catalog::EventProduct.create!(
          event: event,
          name: "Test",
          type: "merchandise",
          min_per_order: 1,
          schedule_change_refund_policy: "full_or_partial"
        )
      Catalog::ProductInventory.create!(
        event_product: product,
        capacity: 10
      )

      assert_nothing_raised do
        ReconcileInventoryJob.perform_now
      end
    end

    test "performs without error even with zero inventories" do
      assert_nothing_raised do
        ReconcileInventoryJob.perform_now
      end
    end
  end
end
