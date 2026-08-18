# frozen_string_literal: true

require "digest"
require "test_helper"

module Parking
  class IssuePackageTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @product, @product_access = create_parking_product
      @order_item = create_parking_order_item(quantity: 2)
    end

    test "issues one parking package with the common credential pipeline" do
      result = IssuePackage.call(order_item: @order_item, unit_number: 1)

      assert_predicate result, :success?, result.error&.message
      ticket = result.value
      assert_equal @product.id, ticket.event_product_id
      assert_nil ticket.registration_id
      assert_equal @buyer.id, ticket.owner_user_id
      assert_equal 1, ticket.admission_slots.count
      assert_equal "parking", ticket.event_product.type
      assert_equal "active", ticket.credentials.sole.status
      assert_equal [ @product_access.id ], ticket.event_product.product_accesses.where(type: "parking").pluck(:id)
    end

    test "replaying one parking unit returns the existing package" do
      first = IssuePackage.call(order_item: @order_item, unit_number: 1)
      second = IssuePackage.call(order_item: @order_item, unit_number: 1)

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :success?, second.error&.message
      assert_equal first.value.id, second.value.id
      assert_equal 1, Ticketing::Ticket.where(order_item_id: @order_item.id).count
    end

    test "fulfills every parking unit without creating a second credential system" do
      result = Prosopite.pause { FulfillOrderItem.call(order_item: @order_item) }

      assert_predicate result, :success?, result.error&.message
      assert_equal [ 1, 2 ], result.value.map(&:unit_number)
      assert_equal 2, Ticketing::Ticket.where(order_item_id: @order_item.id).count
      assert_equal 2, Ticketing::Credential.where(ticket_id: result.value.map(&:id)).count
    end

    test "orders payment fulfillment dispatches parking items through this boundary" do
      event = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.payment.fulfilled",
        aggregate: @order_item.order,
        payload: { order_id: @order_item.order_id, order_item_ids: [ @order_item.id ] },
        idempotency_key: "parking-order-fulfilled-#{@order_item.order_id}"
      ).value

      result = Prosopite.pause do
        Rails.application.config.x.outbox_handlers.fetch(event.event_type).call(event)
      end

      assert_predicate result, :success?, result.error&.message
      assert_equal [ 1, 2 ], Ticketing::Ticket.where(order_item_id: @order_item.id).order(:unit_number).pluck(:unit_number)
    end

    test "rejects a parking order item before it is fulfilled" do
      @order_item.update!(fulfillment_status: "pending")
      @order_item.order.update_columns(status: "pending_payment", paid_at: nil)

      result = FulfillOrderItem.call(order_item: @order_item)

      assert_predicate result, :failure?
      assert_equal "parking_source_not_fulfillable", result.error.code
      assert_empty Ticketing::Ticket.where(order_item_id: @order_item.id)
    end

    private

    def create_parking_product
      product = Catalog::EventProduct.create!(
        event: @event,
        name: "Parking #{SecureRandom.hex(4)}",
        type: "parking",
        status: "active",
        inventory_mode: "unlimited",
        schedule_change_refund_policy: "full_or_partial",
        min_per_order: 1
      )
      event_date = @event.event_dates.create!(
        starts_at: 1.hour.ago,
        ends_at: 2.hours.from_now,
        status: "scheduled"
      )
      access = product.product_accesses.create!(event_date:, type: "parking", usage_limit: 1)
      [ product, access ]
    end

    def create_parking_order_item(quantity:)
      total = 500 * quantity
      order = Orders::Order.create!(
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: total,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: total,
        settlement_currency: "ETB",
        settlement_total_minor: total,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        expires_at: 1.hour.from_now,
        idempotency_key_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
        creation_request_digest: Digest::SHA256.hexdigest(SecureRandom.uuid)
      )
      item = order.order_items.create!(
        event_product: @product,
        name_snapshot: @product.name,
        type_snapshot: "parking",
        quantity:,
        admissions_per_unit_snapshot: nil,
        base_currency: "ETB",
        base_unit_amount_minor: 500,
        charge_currency: "ETB",
        charge_unit_amount_minor: 500,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: total,
        fulfillment_status: "fulfilled"
      )
      order.update_columns(status: "fulfilled", paid_at: Time.current)
      item.reload
    end
  end
end
