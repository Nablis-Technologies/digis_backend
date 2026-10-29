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
      buyers = Core::User.where(email: %w[attendee@example.com support@digis.et]).to_a
      Orders::Order.where(event: @event, buyer_user: buyers).active_checkouts.update_all(
        status: "cancelled", closed_reason: "test_cleanup"
      )
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
      if @proof_ticket_product
        Ticketing::Registration.where(id: @proof_registration.id).delete_all
        Ticketing::AccessCode.where(id: @proof_access_code.id).delete_all
        Ticketing::TicketType.where(id: @proof_ticket_type.id).delete_all
        Catalog::ProductPrice.where(event_product_id: @proof_ticket_product.id).delete_all
        Catalog::EventProduct.where(id: @proof_ticket_product.id).delete_all
      end
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

    test "concurrent final expiry scans restore audience proof only once" do
      buyer = core_users(:support)
      product, ticket_type = create_ticket_product_and_registration(buyer:)
      quote_result = Orders::BuildQuote.call(
        event: @event,
        buyer:,
        items: [ { product:, registration_id: @proof_registration.id, quantity: 1 } ],
        charge_currency: "ETB",
        quoted_at: @quoted_at
      )
      assert_predicate quote_result, :success?, quote_result.error&.message
      order_result = Orders::CreateCheckout.call(
        quote: quote_result.value,
        event: @event,
        buyer:,
        idempotency_key: "proof-expiry-race-order-#{SecureRandom.hex(4)}"
      )
      assert_predicate order_result, :success?, order_result.error&.message
      order = order_result.value
      expiry_time = order.expires_at + 1.second

      race = run_database_race(worker_count: 2) do
        Orders::ExpireCheckout.call(now: expiry_time)
      end

      assert_empty race.errors, race.errors.inspect
      assert race.results.all?(&:success?), race.results.map { |result| result.error&.message }
      assert_equal "expired", order.reload.status
      assert_equal "expired", @proof_registration.reload.status
      assert_equal 0, @proof_access_code.reload.used_count
      assert_equal 1, Core::AuditLog.where(
        auditable_type: "Ticketing::Registration",
        auditable_id: @proof_registration.id,
        action: "ticketing.registration.audience_proof_released"
      ).count
      assert_equal ticket_type.id, @proof_registration.reload.ticket_type_id
    end

    private

    def create_ticket_product_and_registration(buyer:)
      @proof_ticket_product = Catalog::EventProduct.new(
        event: @event,
        name: "Concurrent proof ticket #{SecureRandom.hex(4)}",
        type: "ticket",
        status: "active",
        inventory_mode: "unlimited",
        schedule_change_refund_policy: "full_or_partial",
        min_per_order: 1
      )
      @proof_ticket_type = @proof_ticket_product.build_ticket_type(
        audience: "access_code",
        approval_mode: "automatic",
        date_selection: "fixed",
        admissions_per_unit: 1,
        delegation_validation_mode: "offline_allowed",
        entry_validation_mode: "qr",
        transfer_cutoff_seconds_before_start: 0,
        resale_enabled: false,
        resale_cutoff_seconds_before_start: 0,
        max_completed_resales: 1
      )
      @proof_ticket_product.save!
      Catalog::ProductPrice.create!(
        event_product: @proof_ticket_product,
        type: "base",
        currency: "ETB",
        amount_minor: 1_000,
        active_from: @quoted_at - 1.hour
      )
      @proof_registration = Ticketing::Registration.create!(
        event: @event,
        ticket_type: @proof_ticket_type,
        user: buyer,
        created_by: buyer,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        next_action_snapshot: "requires_order",
        submitted_at: @quoted_at
      )
      raw_code = "CONCURRENT-PROOF-#{SecureRandom.hex(4)}"
      @proof_access_code = Ticketing::AccessCode.create!(
        ticket_type: @proof_ticket_type,
        code: raw_code,
        code_digest: Ticketing::AccessCode.code_digest_for(event_id: @event.id, code: raw_code),
        max_uses: 5,
        used_count: 1,
        max_quantity_per_use: 1,
        active: true
      )
      @proof_registration.update!(access_code: @proof_access_code)
      [ @proof_ticket_product, @proof_ticket_type ]
    end

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
