# frozen_string_literal: true

require "digest"
require "test_helper"

module Orders
  class ResolveManualBillingPurchaseRefundTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @placement, @purchase, @payment = create_paid_placement
      @refund = Orders::Refund.create!(
        payment: @payment, billing_purchase: @purchase, type: "billing_purchase_refund",
        idempotency_key: Digest::SHA256.hexdigest("manual-refund"), amount_minor: 5_000,
        currency: "ETB", status: "manual_review", reason_code: "featured_placement_cancelled",
        pending_reason: "provider_partial_refund_unsupported"
      )
      @operator = core_users(:super_admin)
    end

    test "records external refund evidence and publishes the standard succeeded event" do
      result = resolve

      assert_predicate result, :success?, result.error&.message
      refund = @refund.reload
      assert_equal "succeeded", refund.status
      assert_equal @operator.id, refund.manual_resolved_by_id
      assert_equal "Confirmed in Chapa test dashboard", refund.manual_resolution_reason
      assert_equal "CHAPA-REF-123", refund.manual_evidence_reference
      outbox = Core::OutboxEvent.find_by!(event_type: "orders.refund.succeeded", aggregate: refund)
      assert_equal refund.id, outbox.payload.fetch("refund_id")
      assert_equal "billing_purchase_refund", outbox.payload.fetch("refund_type")
    end

    test "replays idempotently and rejects changed resolution evidence under the same key" do
      first = resolve
      replay = resolve
      conflict = resolve(reason: "Different confirmed refund evidence")

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert replay.value.replayed
      assert_equal first.value.refund.id, replay.value.refund.id
      assert_predicate conflict, :failure?
      assert_equal "idempotency_conflict", conflict.error.code
      assert_equal 1, Core::OutboxEvent.where(event_type: "orders.refund.succeeded", aggregate: @refund).count
    end

    test "attendee cannot resolve a manual billing refund" do
      result = resolve_as(core_users(:attendee), key: "manual-refund-attendee")

      assert_predicate result, :failure?
      assert_equal "manual_resolution_forbidden", result.error.code
      assert_equal "manual_review", @refund.reload.status
    end

    test "core admin cannot resolve a manual billing refund reserved for super-admins" do
      result = resolve_as(core_users(:core_admin), key: "manual-refund-core-admin")

      assert_predicate result, :failure?
      assert_equal "manual_resolution_forbidden", result.error.code
      assert_equal "manual_review", @refund.reload.status
    end

    test "does not resolve without a bounded evidence reference" do
      result = resolve(evidence_reference: "email:user@example.com")

      assert_predicate result, :failure?
      assert_equal "manual_resolution_invalid", result.error.code
      assert_equal "manual_review", @refund.reload.status
    end

    test "writes one operator audit across idempotent resolution retries" do
      assert_audit_idempotent(
        -> { resolve(key: "manual-refund-audit") },
        action: "orders.billing_purchase_refund.manually_resolved",
        auditable_type: "Orders::Refund", auditable_id: @refund.id
      )
    end

    private

    def resolve(reason: "Confirmed in Chapa test dashboard", evidence_reference: "CHAPA-REF-123",
      key: "manual-refund-resolution")
      Orders::ResolveManualBillingPurchaseRefund.call(
        refund: @refund, actor: @operator, reason:, evidence_reference:,
        idempotency_key: key
      )
    end

    def resolve_as(actor, key:)
      Orders::ResolveManualBillingPurchaseRefund.call(
        refund: @refund, actor:, reason: "Confirmed in Chapa dashboard",
        evidence_reference: "CHAPA-REF-123", idempotency_key: key
      )
    end

    def create_paid_placement
      offer = Marketing::PlacementOffer.create!(
        code: "manual_discovery", version: 1, daily_rate_minor: 10_000, currency: "ETB",
        minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
        surface: "public_discovery", terms_version: "v1", status: "active",
        created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
        idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32),
        starts_at: 1.day.ago, ends_at: 30.days.from_now
      )
      starts_at = 1.hour.from_now.change(usec: 0)
      price_digest = Digest::SHA256.hexdigest("manual-refund-price")
      placement = Marketing::FeaturedPlacement.create!(
        event: @event, organization_id: @event.organization_id, placement_offer: offer,
        status: "cancelled", surface: "public_discovery", starts_at:, ends_at: starts_at + 24.hours,
        duration_seconds: 24.hours.to_i, offer_code: offer.code, offer_version: offer.version,
        daily_rate_minor: offer.daily_rate_minor, amount_minor: 10_000, currency: "ETB",
        terms_version: offer.terms_version, price_digest:,
        idempotency_key_digest: Digest::SHA256.hexdigest("manual-placement"),
        request_digest: Digest::SHA256.hexdigest("manual-request")
      )
      purchase = Orders::BillingPurchase.create!(
        organization_id: @event.organization_id, requested_by: core_users(:super_admin),
        kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: placement.id,
        currency: "ETB", amount_minor: 10_000, price_digest:, status: "paid",
        idempotency_key_digest: Digest::SHA256.hexdigest("manual-purchase"), expires_at: 30.minutes.from_now
      )
      payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 10_000, currency: "ETB", accepted_at: Time.current,
        succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "manual-payment",
        settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
      )
      [ placement, purchase, payment ]
    end
  end
end
