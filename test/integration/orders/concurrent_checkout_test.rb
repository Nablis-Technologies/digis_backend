# frozen_string_literal: true

require "test_helper"

module Orders
  class ConcurrentCheckoutTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include Commercial::GovernanceTestHelpers

    setup do
      @event = events_events(:draft_concert)
      @quoted_at = Time.current.change(usec: 0)
      create_checkout_terms
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Last checkout unit",
        type: "parking",
        status: "active",
        inventory_mode: "event_wide",
        schedule_change_refund_policy: "full_or_partial",
        min_per_order: 1
      )
      Catalog::ProductPrice.create!(
        event_product: @product,
        type: "base",
        currency: "ETB",
        amount_minor: 1_000,
        active_from: @quoted_at - 1.hour
      )
      Catalog::ProductInventory.create!(event_product: @product, capacity: 1)
      quote = Orders::BuildQuote.call(
        event: @event,
        items: [ { product: @product, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )
      assert_predicate quote, :success?, quote.error&.message
      buyers = Core::User.where(email: %w[attendee@example.com support@digis.et]).to_a
      @quotes = buyers.map { |buyer| [ buyer, quote.value ] }
    end

    teardown do
      buyer_ids = Array(@quotes).map { |buyer, _quote| buyer.id }
      order_ids = Orders::Order.where(event: @event, buyer_user_id: buyer_ids).pluck(:id)
      item_ids = Orders::OrderItem.where(order_id: order_ids).pluck(:id)
      Catalog::InventoryReservation.where(order_item_id: item_ids).delete_all
      Catalog::VenueCapacityReservation.where(order_item_id: item_ids).delete_all
      Orders::PromotionRedemption.where(order_id: order_ids).delete_all
      Commercial::SubsidyReservation.where(order_id: order_ids).delete_all
      Commercial::VolumeUsage.where(order_id: order_ids).delete_all
      Orders::Order.where(id: order_ids).update_all(status: "draft", paid_at: nil, closed_reason: nil)
      Orders::OrderAdjustment.where(order_id: order_ids).delete_all
      Orders::OrderItem.where(order_id: order_ids).delete_all
      Core::OutboxEvent.where(aggregate_type: "Orders::Order", aggregate_id: order_ids).delete_all
      Orders::Order.where(id: order_ids).delete_all
      if @product
        Catalog::ProductInventory.where(event_product: @product).delete_all
        Catalog::ProductPrice.where(event_product: @product).delete_all
        Catalog::EventProduct.where(id: @product.id).delete_all
      end
      if @version
        Commercial::FeeScheduleVersion.where(id: @version.id).update_all(
          status: "draft", activated_by_id: nil, activated_at: nil
        )
        Commercial::FeeComponent.where(fee_schedule_version_id: @version.id).delete_all
        Commercial::FeeScheduleVersion.where(id: @version.id).delete_all
      end
      Commercial::FeeSchedule.where(id: @schedule&.id).delete_all if @schedule
    end

    test "only one buyer wins the final checkout inventory unit" do
      race = run_database_race(worker_count: @quotes.length) do |index|
        buyer, quote = @quotes.fetch(index)
        Orders::CreateCheckout.call(
          quote:, event: Events::Event.find(@event.id), buyer: Core::User.find(buyer.id),
          idempotency_key: "race-#{buyer.id}-#{SecureRandom.hex(4)}"
        )
      end
      results = race.results

      assert_empty race.errors, race.errors.inspect
      assert_equal 1, results.count(&:success?)
      assert_equal 1, results.count(&:failure?)
      assert_equal "inventory_unavailable", results.find(&:failure?).error.code
      assert_equal 1, @product.inventories.reload.first.held_count
    end

    private

    def create_checkout_terms
      @schedule = create_schedule(
        code: "checkout_race_#{SecureRandom.hex(5)}",
        schedule_type: "platform_default"
      )
      @version = create_version(@schedule, effective_from: @quoted_at - 1.day)
      create_component(@version, rate_bps: 750, label: "Platform commission")
      create_component(
        @version,
        component_type: "buyer_service_fee",
        calculation_type: "percentage",
        charged_to: "buyer",
        funded_by: "buyer",
        basis_type: "eligible_order_subtotal",
        rate_bps: 100,
        label: "Buyer service fee"
      )
      create_component(
        @version,
        component_type: "processing_cost_recovery",
        calculation_type: "explicit_zero",
        charged_to: "buyer",
        funded_by: "buyer",
        basis_type: nil,
        rate_bps: nil,
        label: "Processing cost recovery"
      )
      sync_definition_digest(@version)
      @version.update!(status: "active", activated_by: core_users(:super_admin), activated_at: @quoted_at - 1.day)
    end
  end
end
