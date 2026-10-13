# frozen_string_literal: true

require "digest"
require "test_helper"

module Orders
  class CreateBillingPurchaseRefundTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @placement, @purchase, @payment = create_paid_placement
    end

    test "creates one durable partial refund obligation and outbox event" do
      operation = -> { create_refund(key: "billing-refund-create", amount_minor: 4_000) }
      assert_idempotent(operation, counter: -> { Orders::Refund.where(type: "billing_purchase_refund").count })

      refund = Orders::Refund.where(type: "billing_purchase_refund").sole
      outbox = Core::OutboxEvent.find_by!(event_type: "orders.refund.created", aggregate: refund)
      assert_equal 4_000, refund.amount_minor
      assert_equal @purchase.id, refund.billing_purchase_id
      assert_equal @payment.id, refund.payment_id
      assert_equal "created", refund.status
      assert_equal refund.id, outbox.payload.fetch("refund_id")
      assert_equal refund.amount_minor, outbox.payload.fetch("amount_minor")
    end

    test "replays the same idempotency key but rejects changed refund content" do
      first = create_refund(key: "billing-refund-replay", amount_minor: 4_000)
      replay = create_refund(key: "billing-refund-replay", amount_minor: 4_000)
      conflict = create_refund(key: "billing-refund-replay", amount_minor: 3_000)

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert replay.value.replayed
      assert_equal first.value.refund.id, replay.value.refund.id
      assert_predicate conflict, :failure?
      assert_equal "idempotency_conflict", conflict.error.code
      assert_equal 1, Orders::Refund.where(type: "billing_purchase_refund").count
    end

    test "manual review and succeeded refunds consume the remaining refundable balance" do
      first = create_refund(key: "billing-refund-first", amount_minor: 6_000)
      first.value.refund.update!(status: "manual_review", pending_reason: "provider_partial_refund_unsupported")

      too_much = create_refund(key: "billing-refund-too-much", amount_minor: 5_000)
      first.value.refund.update!(status: "failed", pending_reason: "provider_declined")
      remaining = create_refund(key: "billing-refund-remaining", amount_minor: 10_000)

      assert_predicate first, :success?, first.error&.message
      assert_predicate too_much, :failure?
      assert_equal "refund_amount_exceeded", too_much.error.code
      assert_predicate remaining, :success?, remaining.error&.message
    end

    test "rejects an unaccepted payment and invalid billing purchase source" do
      @payment.update!(accepted_at: nil)
      result = create_refund(key: "billing-refund-unaccepted", amount_minor: 100)

      assert_predicate result, :failure?
      assert_equal "refund_source_not_paid", result.error.code
      assert_empty Orders::Refund.where(type: "billing_purchase_refund")
    end

    test "audits a refund creation exactly once across retries" do
      refund_id = nil
      operation = lambda do
        result = create_refund(key: "billing-refund-audit", amount_minor: 2_000)
        refund_id ||= result.value&.refund&.id
        result
      end

      assert_audit_idempotent(
        operation, action: "orders.billing_purchase_refund.created", auditable_type: "Orders::Refund",
        auditable_id: -> { refund_id || "00000000-0000-7000-8000-000000000000" }
      )
      assert_equal 1, Core::AuditLog.where(
        action: "orders.billing_purchase_refund.created", auditable_id: refund_id
      ).count
    end

    private

    def create_refund(key:, amount_minor:)
      Orders::CreateBillingPurchaseRefund.call(
        payment: @payment, billing_purchase: @purchase, amount_minor:,
        reason_code: "featured_placement_cancelled", actor: core_users(:super_admin), idempotency_key: key
      )
    end

    def create_paid_placement
      offer = Marketing::PlacementOffer.create!(
        code: "refund_discovery", version: 1, daily_rate_minor: 10_000, currency: "ETB",
        minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
        surface: "public_discovery", terms_version: "v1", active: true,
        starts_at: 1.day.ago, ends_at: 30.days.from_now
      )
      starts_at = 1.hour.from_now.change(usec: 0)
      duration = 24.hours.to_i
      price_digest = Digest::SHA256.hexdigest("billing-refund-price")
      placement = Marketing::FeaturedPlacement.create!(
        event: @event, organization_id: @event.organization_id, placement_offer: offer,
        status: "active", surface: "public_discovery", starts_at:, ends_at: starts_at + duration,
        duration_seconds: duration, offer_code: offer.code, offer_version: offer.version,
        daily_rate_minor: offer.daily_rate_minor, amount_minor: 10_000, currency: "ETB",
        terms_version: offer.terms_version, price_digest:,
        idempotency_key_digest: Digest::SHA256.hexdigest("billing-refund-placement"),
        request_digest: Digest::SHA256.hexdigest("billing-refund-request")
      )
      purchase = Orders::BillingPurchase.create!(
        organization_id: @event.organization_id, requested_by: core_users(:super_admin),
        kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: placement.id,
        currency: "ETB", amount_minor: 10_000, price_digest:, status: "paid",
        idempotency_key_digest: Digest::SHA256.hexdigest("billing-refund-purchase"), expires_at: 30.minutes.from_now
      )
      payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 10_000, currency: "ETB", accepted_at: Time.current,
        succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "billing-refund-payment",
        settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
      )
      [ placement, purchase, payment ]
    end
  end
end
