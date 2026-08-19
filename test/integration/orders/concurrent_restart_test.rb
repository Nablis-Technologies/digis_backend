# frozen_string_literal: true

require "test_helper"

module Orders
  class ConcurrentRestartTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include Commercial::GovernanceTestHelpers

    setup do
      @event = events_events(:draft_concert)
      @buyer = core_users(:attendee)
      @quoted_at = Time.current.change(usec: 0)
      create_checkout_terms
      @product = create_product
      @source = create_order
      @quote = build_quote
    end

    teardown do
      order_ids = Orders::Order.where(event: @event, buyer_user: @buyer).pluck(:id)
      item_ids = Orders::OrderItem.where(order_id: order_ids).pluck(:id)
      Catalog::InventoryReservation.where(order_item_id: item_ids).delete_all
      Catalog::VenueCapacityReservation.where(order_item_id: item_ids).delete_all
      Orders::PromotionRedemption.where(order_id: order_ids).delete_all
      Commercial::SubsidyReservation.where(order_id: order_ids).delete_all
      Core::OutboxEvent.where(aggregate_type: "Orders::Order", aggregate_id: order_ids).delete_all
      replacement_ids = Orders::Order.where(id: order_ids).where.not(replaces_order_id: nil).pluck(:id)
      [ *replacement_ids, *(order_ids - replacement_ids) ].each do |order_id|
        Orders::Order.where(id: order_id).update_all(status: "draft", paid_at: nil, closed_reason: nil)
        Orders::OrderAdjustment.where(order_id: order_id).delete_all
        Orders::OrderItem.where(order_id: order_id).delete_all
        Orders::Order.where(id: order_id).delete_all
      end
      Catalog::ProductInventory.where(event_product: @product).delete_all
      Catalog::ProductPrice.where(event_product: @product).delete_all
      Catalog::EventProduct.where(id: @product.id).delete_all
      delete_commercial_terms
    end

    test "concurrent restarts with one key return one replacement" do
      race = run_database_race do
        Orders::RestartCheckout.call(
          old_order: Orders::Order.find(@source.id), buyer: Core::User.find(@buyer.id),
          quote: @quote, idempotency_key: "concurrent-restart"
        )
      end
      results = race.results

      assert_empty race.errors, race.errors.inspect
      assert results.all?(&:success?), results.map { |result| result.error&.message }
      assert_equal 1, results.map { |result| result.value.id }.uniq.length
      assert_equal 1, Orders::Order.where(replaces_order_id: @source.id).count
      assert_equal 1, Orders::Order.active_checkouts.where(event: @event, buyer_user: @buyer).count
    end

    private

    def create_order
      result = Orders::CreateCheckout.call(
        quote: build_quote,
        event: @event,
        buyer: @buyer,
        idempotency_key: "concurrent-restart-source"
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end

    def build_quote
      result = Orders::BuildQuote.call(
        event: @event,
        buyer: @buyer,
        items: [ { product: @product, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: Time.current.change(usec: 0)
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end

    def create_checkout_terms
      @schedule = create_schedule(code: "restart_race_#{SecureRandom.hex(5)}", schedule_type: "platform_default")
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

    # These definitions are immutable by design. The non-transactional race test
    # must remove its isolated fixtures explicitly after the concurrent run.
    def delete_commercial_terms
      return unless @version && @schedule

      connection = Commercial::ApplicationRecord.connection
      connection.execute("ALTER TABLE commercial_fee_components DISABLE TRIGGER trg_commercial_fee_component_immutable")
      connection.execute("ALTER TABLE commercial_fee_schedule_versions DISABLE TRIGGER trg_commercial_fee_schedule_version_immutable")
      begin
        Commercial::FeeComponent.where(fee_schedule_version_id: @version.id).delete_all
        Commercial::FeeScheduleVersion.where(id: @version.id).delete_all
        Commercial::FeeSchedule.where(id: @schedule.id).delete_all
      ensure
        connection.execute("ALTER TABLE commercial_fee_components ENABLE TRIGGER trg_commercial_fee_component_immutable")
        connection.execute("ALTER TABLE commercial_fee_schedule_versions ENABLE TRIGGER trg_commercial_fee_schedule_version_immutable")
      end
    end

    def create_product
      product = Catalog::EventProduct.create!(
        event: @event,
        name: "Concurrent restart parking",
        type: "parking",
        status: "active",
        inventory_mode: "event_wide",
        schedule_change_refund_policy: "full_or_partial",
        min_per_order: 1
      )
      Catalog::ProductPrice.create!(
        event_product: product,
        type: "base",
        currency: "ETB",
        amount_minor: 1_000,
        active_from: @quoted_at - 1.hour
      )
      Catalog::ProductInventory.create!(event_product: product, capacity: 1)
      product
    end
  end
end
