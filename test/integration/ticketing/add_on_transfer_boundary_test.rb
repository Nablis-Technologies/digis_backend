# frozen_string_literal: true

require "test_helper"

module Ticketing
  class AddOnTransferBoundaryTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_included_parking_package
      @separate_parking_item = create_separate_parking_order_item
      result = Parking::FulfillOrderItem.call(order_item: @separate_parking_item)
      assert_predicate result, :success?, result.error&.message
      @separate_parking_ticket = result.value.sole
    end

    test "included parking follows the ticket while separate parking retains its owner" do
      initiated = Ticketing::Transfers::Initiate.call(
        ticket: @ticket,
        actor: @owner,
        phone: @recipient.phone,
        idempotency_key: "parking-transfer-initiate"
      )
      assert_predicate initiated, :success?, initiated.error&.message

      accepted = Ticketing::Transfers::Accept.call(
        token: initiated.value.token,
        actor: @recipient
      )

      assert_predicate accepted, :success?, accepted.error&.message
      assert_equal @recipient.id, @ticket.reload.owner_user_id
      assert @ticket.event_product.product_accesses.any?(&:parking?)
      assert_equal @owner.id, @separate_parking_ticket.reload.owner_user_id
    end

    test "delegating a ticket does not assign a separate parking package" do
      result = Ticketing::Delegations::Activate.call(
        ticket: @ticket,
        actor: @owner,
        assignments: { 1 => @recipient, 2 => nil, 3 => nil },
        idempotency_key: "parking-delegation"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal @owner.id, @ticket.reload.owner_user_id
      assert_equal @owner.id, @separate_parking_ticket.reload.owner_user_id
      assert_equal 1, Ticketing::Ticket.where(order_item_id: @separate_parking_item.id).count
    end

    private

    def setup_included_parking_package
      @event = events_events(:ready_listing)
      @owner = core_users(:attendee)
      @recipient = core_users(:core_admin)
      @other_user = core_users(:support)
      @manager = core_users(:super_admin)
      @product = create_package_product(admissions_per_unit: 3, delegation_enabled: true, transferable: true)
      @included_parking = @product.product_accesses.create!(
        event_date: @product.product_accesses.first.event_date,
        type: "parking",
        usage_limit: 1
      )
      @registration = create_confirmed_registration
      @ticket = create_issued_ticket
    end

    def create_separate_parking_order_item
      product = Catalog::EventProduct.create!(
        event: @event,
        name: "Separate parking #{SecureRandom.hex(4)}",
        type: "parking",
        status: "active",
        inventory_mode: "unlimited",
        schedule_change_refund_policy: "full_or_partial",
        min_per_order: 1
      )
      date = @event.event_dates.create!(
        starts_at: 2.days.from_now,
        ends_at: 2.days.from_now + 4.hours,
        status: "scheduled"
      )
      product.product_accesses.create!(event_date: date, type: "parking", usage_limit: 1)
      order = Orders::Order.create!(
        event: @event,
        buyer_user: @owner,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "b" * 64,
        subtotal_minor: 500,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 500,
        settlement_currency: "ETB",
        settlement_total_minor: 500,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        expires_at: 1.hour.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      item = order.order_items.create!(
        event_product: product,
        name_snapshot: product.name,
        type_snapshot: "parking",
        quantity: 1,
        admissions_per_unit_snapshot: nil,
        base_currency: "ETB",
        base_unit_amount_minor: 500,
        charge_currency: "ETB",
        charge_unit_amount_minor: 500,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: 500,
        fulfillment_status: "fulfilled"
      )
      order.update_columns(status: "fulfilled", paid_at: Time.current)
      item.reload
    end
  end
end
