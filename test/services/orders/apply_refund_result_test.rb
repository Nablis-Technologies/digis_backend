# frozen_string_literal: true

require "digest"
require "test_helper"

module Orders
  class ApplyRefundResultTest < ActiveSupport::TestCase
    include Orders::GiftPurchaseTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      Orders::Order.where(event: @event, buyer_user: @buyer).where(status: %w[draft pending_payment]).update_all(
        status: "cancelled", closed_reason: "test_cleanup"
      )
      @refund = create_refund
    end

    test "records a provider fee reported after the refund already succeeded" do
      @refund.update!(status: "succeeded", provider_reference: "refund-ref")
      result = Orders::ApplyRefundResult.call(
        refund: @refund,
        result: Payments::Providers::Result.success(
          provider_reference: "refund-ref", provider_fee_minor: 25, provider_fee_currency: "ETB"
        )
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "succeeded", result.value.status
      assert_equal 1_000, result.value.amount_minor
      assert_equal 25, result.value.provider_fee_minor
      assert_equal "ETB", result.value.provider_fee_currency
    end

    test "replays a duplicate successful provider callback without changing the refund amount" do
      @refund.update!(status: "processing")
      provider_result = Payments::Providers::Result.success(provider_reference: "refund-ref")

      first = Orders::ApplyRefundResult.call(refund: @refund, result: provider_result)
      replay = Orders::ApplyRefundResult.call(refund: @refund, result: provider_result)

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert_equal first.value.id, replay.value.id
      assert_equal "succeeded", replay.value.status
      assert_equal 1_000, replay.value.amount_minor
    end

    test "keeps timeout and unknown results processing for later verification" do
      @refund.update!(status: "processing")
      now = Time.current.change(usec: 0)

      result = Orders::ApplyRefundResult.call(
        refund: @refund,
        result: Payments::Providers::Result.timeout(
          provider_reference: "maybe-ref", raw_status: "gateway_timeout"
        ), now:
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "processing", result.value.status
      assert_equal "provider_processing", result.value.pending_reason
      assert_equal "maybe-ref", result.value.provider_reference
      assert_operator result.value.next_retry_at, :>, now
    end

    test "records a provider failure without changing the promised amount" do
      @refund.update!(status: "processing")

      result = Orders::ApplyRefundResult.call(
        refund: @refund,
        result: Payments::Providers::Result.failure(failure_code: "declined", raw_status: "declined")
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "failed", result.value.status
      assert_equal "declined", result.value.pending_reason
      assert_equal 1_000, result.value.amount_minor
    end

    test "routes a definitive featured billing refund refusal to manual review" do
      refund = create_featured_billing_refund
      refund.update!(status: "processing")

      result = Orders::ApplyRefundResult.call(
        refund:, result: Payments::Providers::Result.failure(failure_code: "rail_partial_refund_unsupported")
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "manual_review", refund.reload.status
      assert_equal "rail_partial_refund_unsupported", refund.pending_reason
      assert_equal 1, Core::AuditLog.where(
        action: "orders.billing_purchase_refund.manual_review", auditable_id: refund.id
      ).count
    end

    test "rejects provider fee evidence without a currency and preserves processing state" do
      @refund.update!(status: "processing")

      result = Orders::ApplyRefundResult.call(
        refund: @refund,
        result: Payments::Providers::Result.success(provider_reference: "refund-ref", provider_fee_minor: 25)
      )

      assert_predicate result, :failure?
      assert_equal "invalid_provider_result", result.error.code
      assert_equal "processing", @refund.reload.status
      assert_nil @refund.provider_fee_minor
    end

    test "successful refund revokes an unclaimed gift and releases its recipient allocation" do
      setup_gift_purchase_context
      payment = create_gift_payment
      allocation = Ticketing::PurchaseLimitAllocation.create!(
        ticket_type: @gift_ticket_type,
        user: @gift_purchase.recipient_user,
        registration: @gift_registration,
        unit_number: 1,
        status: "committed",
        committed_at: Time.current,
        idempotency_key: "gift-refund-limit-#{SecureRandom.hex(5)}"
      )
      refund = create_gift_refund(payment:)

      result = Orders::ApplyRefundResult.call(
        refund:,
        result: Payments::Providers::Result.success(provider_reference: "gift-refund")
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "revoked", @gift_purchase.reload.status
      assert_equal "cancelled", @gift_registration.reload.status
      assert_equal "released", allocation.reload.status
      assert_nil refund.refund_items.sole.ticket_id
    end

    test "successful refund after claim revokes the gift link and existing refund handler revokes its ticket" do
      setup_gift_purchase_context
      _form, _version, question = create_required_gift_form
      claimed = Orders::GiftPurchases::Claim.call(
        gift_purchase_id: @gift_purchase.id,
        token: @gift_token,
        submission: Ticketing::RegistrationSubmission.new(
          package_quantity: 1,
          selected_event_date_id: nil,
          answers: [ { question_key: question.key, value: "Recipient" } ],
          consents: []
        ),
        idempotency_key: "gift-refund-after-claim"
      )
      assert_predicate claimed, :success?, claimed.error&.message
      payment = create_gift_payment

      cancellation = Events::Cancellation::Initiate.call(
        event: @gift_event,
        actor: core_users(:core_admin),
        idempotency_key: "claimed-gift-event-cancellation",
        attendee_reason: "Event cancelled"
      ).value
      prepared = Events::Cancellation::PrepareBatch.call(cancellation:)
      assert_predicate prepared, :success?, prepared.error&.message

      refund = Orders::CreateItemRefund.call(
        payment:,
        order_item: @gift_order_item,
        ticket: claimed.value.ticket,
        quantity: 1,
        reason_code: "event_cancellation",
        idempotency_key: "claimed-gift-refund",
        event_cancellation: cancellation
      ).value

      result = Orders::ApplyRefundResult.call(
        refund:,
        result: Payments::Providers::Result.success(provider_reference: "claimed-gift-refund")
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "revoked", @gift_purchase.reload.status
      assert_equal "active", claimed.value.ticket.reload.status
      transition = Ticketing::CancelPaidPackage.call(ticket: claimed.value.ticket, refund:)
      assert_predicate transition, :success?, "#{transition.error&.message} #{transition.error&.errors.inspect}"
      create_messaging_policy
      outbox_event = Core::OutboxEvent.find_by!(event_type: "orders.refund.succeeded", aggregate_id: refund.id)
      handler = Rails.application.config.x.outbox_handlers.fetch(outbox_event.event_type)
      handled = handler.call(outbox_event)
      assert_predicate handled, :success?, handled.error&.message
      assert_equal "refunded", claimed.value.ticket.reload.status
      assert claimed.value.ticket.package_dead?
    end

    test "failed refund leaves the recipient gift link usable" do
      setup_gift_purchase_context
      payment = create_gift_payment
      refund = create_gift_refund(payment:)

      result = Orders::ApplyRefundResult.call(
        refund:,
        result: Payments::Providers::Result.failure(failure_code: "declined", raw_status: "declined")
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "ready", @gift_purchase.reload.status
      assert_equal "gift_pending_claim", @gift_registration.reload.status
    end

    private

    def create_refund
      order = Orders::Order.create!(
        event: @event, buyer_user: @buyer, sales_channel: "online", status: "draft",
        charge_currency: "ETB", commercial_signature: "a" * 64,
        subtotal_minor: 1_000, discount_minor: 0, subsidy_minor: 0, fee_minor: 0,
        tax_minor: 0, adjustment_minor: 0, total_minor: 1_000,
        settlement_currency: "ETB", settlement_total_minor: 1_000, exchange_rate: 1,
        exchange_rate_source: "same_currency", exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now, idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      product = Catalog::EventProduct.create!(
        event: @event, name: "Refund result product #{SecureRandom.hex(4)}",
        type: "merchandise", status: "active"
      )
      item = Orders::OrderItem.create!(
        order:, event_product: product, name_snapshot: product.name, type_snapshot: "merchandise",
        quantity: 1, base_currency: "ETB", base_unit_amount_minor: 1_000,
        charge_currency: "ETB", charge_unit_amount_minor: 1_000, exchange_rate: 1,
        discount_minor: 0, total_minor: 1_000, fulfillment_status: "fulfilled"
      )
      order.update!(status: "fulfilled", paid_at: Time.current)
      payment = Orders::Payment.create!(
        order:, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 1_000, currency: "ETB",
        commercial_signature: order.commercial_signature, buyer_fee_minor: 0, organizer_fee_minor: 0,
        idempotency_key: "payment-#{SecureRandom.hex(6)}", provider_reference: "provider-#{SecureRandom.hex(4)}",
        accepted_at: Time.current, succeeded_at: Time.current,
        settlement_grace_minutes: 5, settlement_grace_expires_at: order.expires_at + 5.minutes
      )
      result = Orders::CreateItemRefund.call(
        payment:, order_item: item, quantity: 1, reason_code: "event_cancellation",
        idempotency_key: "apply-refund-#{SecureRandom.hex(6)}"
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end

    def create_featured_billing_refund
      price_digest = Digest::SHA256.hexdigest("apply-featured-price")
      purchase = Orders::BillingPurchase.create!(
        organization_id: @event.organization_id, requested_by: @buyer,
        kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: SecureRandom.uuid,
        currency: "ETB", amount_minor: 1_000, price_digest:, status: "paid",
        idempotency_key_digest: Digest::SHA256.hexdigest("apply-featured-purchase"),
        expires_at: 30.minutes.from_now
      )
      payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 1_000, currency: "ETB", accepted_at: Time.current,
        succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "apply-featured-payment",
        settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
      )
      Orders::Refund.create!(
        payment:, billing_purchase: purchase, type: "billing_purchase_refund",
        idempotency_key: Digest::SHA256.hexdigest("apply-featured-refund"), amount_minor: 500,
        currency: "ETB", status: "created", reason_code: "featured_placement_cancelled"
      )
    end

    def create_gift_payment
      Orders::Payment.create!(
        order: @gift_order,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "succeeded",
        amount_minor: @gift_order.total_minor,
        currency: @gift_order.charge_currency,
        commercial_signature: @gift_order.commercial_signature,
        buyer_fee_minor: 0,
        organizer_fee_minor: 0,
        idempotency_key: "apply-gift-refund-payment-#{SecureRandom.hex(5)}",
        provider_reference: "apply-gift-refund-provider-#{SecureRandom.hex(4)}",
        accepted_at: Time.current,
        succeeded_at: Time.current,
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @gift_order.expires_at + 5.minutes
      )
    end

    def create_gift_refund(payment:)
      result = Orders::CreateItemRefund.call(
        payment:,
        order_item: @gift_order_item,
        quantity: 1,
        reason_code: "event_cancellation",
        idempotency_key: "apply-gift-refund-#{SecureRandom.hex(5)}"
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end
  end
end
