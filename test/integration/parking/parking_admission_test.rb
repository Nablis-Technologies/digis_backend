# frozen_string_literal: true

require "test_helper"

module Parking
  class ParkingAdmissionTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @manager = core_users(:super_admin)
      @product, @product_access = create_parking_product
      @order_item = create_parking_order_item
      result = Parking::FulfillOrderItem.call(order_item: @order_item)
      assert_predicate result, :success?, result.error&.message
      @ticket = result.value.sole
      @event_date = @product_access.event_date
      @assignment = create_scanner_assignment
    end

    test "parking uses the common QR admission path and its usage limit" do
      claims = Ticketing::Qr::Verifier.call(
        token: @ticket.current_credential_generation.credentials.sole.qr_token
      ).value

      first = Ticketing::Admissions::Consume.call(
        claims:,
        product_access: @product_access,
        assignment: @assignment,
        client_scan_id: SecureRandom.uuid,
        scanned_at: @event_date.starts_at + 1.minute,
        now: @event_date.starts_at + 1.minute
      )
      second = Ticketing::Admissions::Consume.call(
        claims:,
        product_access: @product_access,
        assignment: @assignment,
        client_scan_id: SecureRandom.uuid,
        scanned_at: @event_date.starts_at + 2.minutes,
        now: @event_date.starts_at + 2.minutes
      )

      assert_predicate first, :success?, first.error&.message
      assert_equal "success", first.value.result
      assert_predicate second, :success?, second.error&.message
      assert_equal "duplicate", second.value.result
      assert_equal 1, Ticketing::AdmissionUse.where(product_access: @product_access).count
    end

    private

    def create_parking_product
      product = Catalog::EventProduct.create!(
        event: @event,
        name: "Parking admission #{SecureRandom.hex(4)}",
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

    def create_parking_order_item
      order = Orders::Order.create!(
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
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
        event_product: @product,
        name_snapshot: @product.name,
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

    def create_scanner_assignment
      build_scanner_assignment(
        event: @event,
        assigned_by: @manager,
        device_identifier: "parking-scanner-#{SecureRandom.hex(4)}"
      )
    end
  end
end
