# frozen_string_literal: true

require "test_helper"

module Orders
  class CreateItemRefundTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include Ticketing::PackageWorkflowTestHelpers
    include Ticketing::ConsentTestHelpers
    include Orders::GiftPurchaseTestHelpers

    test "accepts an event cancellation reason" do
      assert_approved_reason("event_cancellation")
    end

    test "accepts an organizer ticket cancellation reason" do
      assert_approved_reason("organizer_ticket_cancellation")
    end

    test "accepts a schedule change reason" do
      assert_approved_reason("schedule_change")
    end

    test "accepts a legal remedy reason" do
      assert_approved_reason("legal_remedy")
    end

    test "accepts a platform admin correction reason" do
      assert_approved_reason("platform_admin_correction")
    end

    test "rejects a voluntary change-of-mind refund" do
      payment, item = create_paid_item

      result = Orders::CreateItemRefund.call(
        payment:, order_item: item, quantity: 1, reason_code: "change_of_mind",
        idempotency_key: "voluntary-refund"
      )

      assert_predicate result, :failure?
      assert_equal "refund_reason_not_allowed", result.error.code
      assert_empty Orders::Refund.where(payment:)
    end

    test "replays the same idempotency key without creating another refund" do
      payment, item = create_paid_item
      arguments = {
        payment:, order_item: item, quantity: 1, reason_code: "event_cancellation",
        idempotency_key: "item-refund-replay"
      }

      first = Orders::CreateItemRefund.call(**arguments)
      replay = Orders::CreateItemRefund.call(**arguments.merge(reason_code: "legal_remedy"))

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert_equal first.value.id, replay.value.id
      assert_equal 1, Orders::Refund.where(payment:).count
      assert_equal 1, Orders::RefundItem.where(refund: first.value).count
    end

    test "includes the signed refundable adjustment in exact item reconciliation" do
      payment, item = create_paid_item(discount_minor: 100)
      adjustment = item.order.order_adjustments.sole
      payment.update_columns(amount_minor: 900)

      result = Orders::CreateItemRefund.call(
        payment:, order_item: item, quantity: 1, reason_code: "event_cancellation",
        idempotency_key: "item-refund-adjustment"
      )

      assert_predicate result, :success?, result.error&.message
      refund_item = result.value.refund_items.sole
      assert_equal 1_000, refund_item.subtotal_minor
      assert_equal 900, refund_item.amount_minor
      assert_equal(-100, refund_item.refund_adjustment_allocations.sole.amount_minor)
      assert_equal adjustment.id, refund_item.refund_adjustment_allocations.sole.order_adjustment_id
    end

    test "does not exceed the original item quantity or value" do
      payment, item = create_paid_item(quantity: 2, unit_amount: 500)
      first = Orders::CreateItemRefund.call(
        payment:, order_item: item, quantity: 1, reason_code: "event_cancellation",
        idempotency_key: "item-refund-first"
      )
      second = Orders::CreateItemRefund.call(
        payment:, order_item: item, quantity: 2, reason_code: "event_cancellation",
        idempotency_key: "item-refund-overage"
      )

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :failure?
      assert_equal "refund_item_value_exceeded", second.error.code
      assert_equal 1, Orders::RefundItem.where(order_item: item).count
      assert_equal 500, Orders::RefundItem.where(order_item: item).sum(:amount_minor)
    end

    test "creates one package row and does not mutate ticket access state" do
      setup_package_workflow(admissions_per_unit: 1)
      payment = create_payment_for(@ticket.order_item)
      ticket_status = @ticket.status
      ticket_version = @ticket.credential_version

      result = Orders::CreateItemRefund.call(
        payment:, order_item: @ticket.order_item, ticket: @ticket, quantity: 1,
        reason_code: "organizer_ticket_cancellation", idempotency_key: "package-refund"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal 1, result.value.refund_items.count
      assert_equal @ticket.id, result.value.refund_items.sole.ticket_id
      assert_equal ticket_status, @ticket.reload.status
      assert_equal ticket_version, @ticket.credential_version
    end

    test "accepts an event-cancellation refund for an unclaimed paid gift without a ticket row" do
      setup_gift_purchase_context
      payment = create_payment_for(@gift_order_item, amount_minor: @gift_order.total_minor)

      result = Orders::CreateItemRefund.call(
        payment:,
        order_item: @gift_order_item,
        quantity: 1,
        reason_code: "event_cancellation",
        idempotency_key: "unclaimed-gift-refund"
      )

      assert_predicate result, :success?, result.error&.message
      assert_nil result.value.refund_items.sole.ticket_id
      assert_equal @gift_order_item.id, result.value.refund_items.sole.order_item_id
    end

    test "discovers and records an already-issued gift ticket when the caller omits ticket" do
      setup_gift_purchase_context
      claim = Orders::GiftPurchases::Claim.call(
        gift_purchase_id: @gift_purchase.id,
        token: @gift_token,
        submission: Ticketing::RegistrationSubmission.new(
          package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
        ),
        idempotency_key: "claimed-gift-before-refund"
      )
      assert_predicate claim, :success?, claim.error&.message
      payment = create_payment_for(@gift_order_item, amount_minor: @gift_order.total_minor)

      result = Orders::CreateItemRefund.call(
        payment:,
        order_item: @gift_order_item,
        quantity: 1,
        reason_code: "event_cancellation",
        idempotency_key: "claimed-gift-refund-without-explicit-ticket"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal claim.value.ticket.id, result.value.refund_items.sole.ticket_id
      assert_equal @gift_order_item.id, result.value.refund_items.sole.order_item_id
    end

    test "event cancellation can refund the payer after an incomplete gift expires" do
      setup_gift_purchase_context
      create_consent_document(scope: "admission_slot", required: true)
      claim = Orders::GiftPurchases::Claim.call(
        gift_purchase_id: @gift_purchase.id,
        token: @gift_token,
        submission: Ticketing::RegistrationSubmission.new(
          package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
        ),
        idempotency_key: "expire-gift-before-event-cancellation-refund"
      )
      assert_predicate claim, :success?, claim.error&.message
      ticket = claim.value.ticket
      expiration = Orders::GiftPurchases::Expire.call(
        gift_purchase: @gift_purchase,
        at: @gift_purchase.expires_at
      )
      assert_predicate expiration, :success?, expiration.error&.message
      expiry_event = Core::OutboxEvent.find_by!(
        event_type: "ticketing.gift_claim.expired",
        aggregate_id: @gift_registration.id
      )
      perform_enqueued_jobs { Core::Outbox::Dispatch.call(event_id: expiry_event.id) }
      assert_equal "void", ticket.reload.status

      payment = create_payment_for(@gift_order_item, amount_minor: @gift_order.total_minor)
      refund_result = Orders::CreateItemRefund.call(
        payment:,
        order_item: @gift_order_item,
        quantity: 1,
        reason_code: "event_cancellation",
        idempotency_key: "cancel-expired-incomplete-gift"
      )

      assert_predicate refund_result, :success?, refund_result.error&.message
      refund = refund_result.value
      assert_equal @gift_purchaser.id, refund.payment.order.buyer_user_id
      assert_equal ticket.id, refund.refund_items.sole.ticket_id
      refund.update_columns(status: "succeeded", provider_reference: "gift-expiry-refund")

      finalized = Ticketing::CancelPaidPackage.call(ticket:, refund:)

      assert_predicate finalized, :success?, finalized.error&.message
      assert_equal "void", ticket.reload.status
    end

    test "rejects a second refund for the same date access" do
      setup_package_workflow(admissions_per_unit: 1)
      event_date = @product.product_accesses.first.event_date
      @product.product_date_allocations.create!(event_date:, allocation_basis_points: 10_000)
      payment = create_payment_for(@ticket.order_item)
      arguments = {
        payment:, order_item: @ticket.order_item, ticket: @ticket, event_date:, quantity: 1,
        reason_code: "schedule_change", idempotency_key: "date-refund-1"
      }

      first = Orders::CreateItemRefund.call(**arguments)
      second = Orders::CreateItemRefund.call(**arguments.merge(idempotency_key: "date-refund-2"))

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :failure?
      assert_equal "refund_date_unavailable", second.error.code
      assert_equal 1, Orders::RefundItem.where(ticket: @ticket, event_date:).count
    end

    test "rejects a date refund after the ticket has been used for that date" do
      setup_package_workflow(admissions_per_unit: 1)
      event_date = @product.product_accesses.first.event_date
      event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
      @product.product_date_allocations.create!(event_date:, allocation_basis_points: 10_000)
      product_access = @product.product_accesses.first
      assignment = create_scanner_assignment
      consume_admission(product_access, event_date, assignment)
      payment = create_payment_for(@ticket.order_item)

      result = Orders::CreateItemRefund.call(
        payment:, order_item: @ticket.order_item, ticket: @ticket, event_date:, quantity: 1,
        reason_code: "schedule_change", idempotency_key: "used-date-refund"
      )

      assert_predicate result, :failure?
      assert_equal "refund_date_unavailable", result.error.code
      assert_empty Orders::RefundItem.where(ticket: @ticket, event_date:)
    end

    private

    def assert_approved_reason(reason)
      payment, item = create_paid_item
      result = Orders::CreateItemRefund.call(
        payment:, order_item: item, quantity: 1, reason_code: reason,
        idempotency_key: "refund-#{reason}"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "item_refund", result.value.type
      assert_equal reason, result.value.reason_code
      assert_equal 1, result.value.refund_items.count
    end

    def create_paid_item(quantity: 1, unit_amount: 1_000, discount_minor: 0)
      event = events_events(:ready_listing)
      buyer = core_users(:attendee)
      product = Catalog::EventProduct.create!(
        event:, name: "Refund product #{SecureRandom.hex(4)}", type: "merchandise", status: "active"
      )
      total = quantity * unit_amount - discount_minor
      order = Orders::Order.create!(
        event:, buyer_user: buyer, sales_channel: "online", status: "draft",
        charge_currency: "ETB", commercial_signature: "a" * 64,
        subtotal_minor: quantity * unit_amount, discount_minor:, subsidy_minor: 0,
        fee_minor: 0, tax_minor: 0, adjustment_minor: 0, total_minor: total,
        settlement_currency: "ETB", settlement_total_minor: total, exchange_rate: 1,
        exchange_rate_source: "same_currency", exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now, idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      item = Orders::OrderItem.create!(
        order:, event_product: product, name_snapshot: product.name, type_snapshot: "merchandise",
        quantity:, base_currency: "ETB", base_unit_amount_minor: unit_amount,
        charge_currency: "ETB", charge_unit_amount_minor: unit_amount, exchange_rate: 1,
        discount_minor:, total_minor: quantity * unit_amount, fulfillment_status: "fulfilled"
      )
      if discount_minor.positive?
        Orders::OrderAdjustment.create!(
          order:, order_item: item, type: "discount", label: "Refundable discount",
          charged_to: "buyer", amount_minor: -discount_minor, currency: "ETB",
          refund_policy: "refundable", calculation_type: "fixed", fixed_amount_minor: discount_minor
        )
        item.update!(discount_minor:, total_minor: quantity * unit_amount - discount_minor)
      end
      order.update!(status: "fulfilled", paid_at: Time.current)
      [ create_payment_for(item, amount_minor: total), item ]
    end

    def create_payment_for(item, amount_minor: item.total_minor)
      order = item.order
      Orders::Payment.create!(
        order:, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor:, currency: order.charge_currency,
        commercial_signature: order.commercial_signature, buyer_fee_minor: 0,
        organizer_fee_minor: 0, idempotency_key: "payment-#{SecureRandom.hex(6)}",
        provider_reference: "provider-#{SecureRandom.hex(4)}", accepted_at: Time.current,
        settlement_grace_minutes: 5, settlement_grace_expires_at: order.expires_at + 5.minutes
      )
    end

    def create_scanner_assignment
      build_scanner_assignment(
        event: @event,
        assigned_by: @manager,
        device_identifier: "refund-date-scanner-#{SecureRandom.hex(4)}"
      )
    end

    def consume_admission(product_access, event_date, assignment)
      claims = Ticketing::Qr::Verifier.call(
        token: @ticket.current_credential_generation.credentials.first.qr_token
      ).value
      result = Ticketing::Admissions::Consume.call(
        claims:, product_access:, assignment:, client_scan_id: SecureRandom.uuid,
        scanned_at: event_date.starts_at + 1.minute, lookup_via: "qr", identity_check: nil,
        now: event_date.starts_at + 1.minute
      )
      assert_predicate result, :success?, result.error&.message
    end
  end
end
