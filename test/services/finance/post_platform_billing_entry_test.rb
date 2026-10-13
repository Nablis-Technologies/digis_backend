# frozen_string_literal: true

require "digest"
require "test_helper"

module Finance
  class PostPlatformBillingEntryTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @placement, @purchase, @payment = create_paid_placement(provider_fee_minor: 25)
    end

    test "posts an accepted platform charge and provider fee once" do
      operation = -> { PostPlatformBillingEntry.call(payment: @payment, billing_purchase: @purchase, type: :charge) }
      assert_idempotent(operation, counter: -> { PlatformBillingEntry.count })

      entries = PlatformBillingEntry.order(:type).to_a
      assert_equal %w[featured_placement_charge provider_fee], entries.map(&:type)
      assert_equal [ 10_000, -25 ], entries.map(&:amount_minor)
    end

    test "journals the accepted billing purchase without querying the product-owned source" do
      @purchase.update_column(:source_id, SecureRandom.uuid)

      result = PostPlatformBillingEntry.call(payment: @payment, billing_purchase: @purchase, type: :charge)

      assert_predicate result, :success?, result.error&.message
      assert_equal [ "featured_placement_charge", "provider_fee" ], result.value.map(&:type)
      assert_equal [ 10_000, -25 ], result.value.map(&:amount_minor)
    end

    test "no-ops for a different typed billing product" do
      top_up_purchase = Orders::BillingPurchase.create!(
        organization_id: @event.organization_id, requested_by: core_users(:super_admin),
        kind: "messaging_credit_top_up", source_type: "Messaging::CreditTopUp", source_id: SecureRandom.uuid,
        currency: "ETB", amount_minor: 1_000, price_digest: Digest::SHA256.hexdigest("other-price"),
        status: "paid", idempotency_key_digest: Digest::SHA256.hexdigest("other-purchase"),
        expires_at: 30.minutes.from_now
      )
      top_up_payment = Orders::Payment.create!(
        billing_purchase: top_up_purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 1_000, currency: "ETB", accepted_at: Time.current,
        succeeded_at: Time.current, billing_purchase_price_digest: top_up_purchase.price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "other-platform-payment",
        settlement_grace_minutes: 5, settlement_grace_expires_at: top_up_purchase.expires_at + 5.minutes
      )

      result = PostPlatformBillingEntry.call(payment: top_up_payment, billing_purchase: top_up_purchase, type: :charge)

      assert_predicate result, :success?, result.error&.message
      assert_empty result.value
      assert_empty PlatformBillingEntry.where(payment_id: top_up_payment.id)
    end

    test "rejects an unsupported journal entry type with a typed localized failure" do
      result = PostPlatformBillingEntry.call(payment: @payment, billing_purchase: @purchase, type: :unknown)

      assert_predicate result, :failure?
      assert_equal "invalid_entry_type", result.error.code
      assert_empty PlatformBillingEntry.where(payment_id: @payment.id)
    end

    test "posts only a succeeded linked billing refund as a negative platform fact" do
      refund = Orders::Refund.create!(
        payment: @payment, billing_purchase: @purchase, type: "billing_purchase_refund",
        idempotency_key: Digest::SHA256.hexdigest("platform-refund"), amount_minor: 4_000,
        currency: "ETB", status: "succeeded", reason_code: "featured_placement_cancelled"
      )

      result = PostPlatformBillingEntry.call(
        payment: @payment, billing_purchase: @purchase, refund:, type: :refund
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "featured_placement_refund", result.value.sole.type
      assert_equal(-4_000, result.value.sole.amount_minor)
      assert_equal refund.id, result.value.sole.refund_id
    end

    test "does not post provider fees when the provider supplied no fee evidence" do
      _placement, purchase, payment = create_paid_placement

      result = PostPlatformBillingEntry.call(payment:, billing_purchase: purchase, type: :charge)

      assert_predicate result, :success?, result.error&.message
      assert_equal [ "featured_placement_charge" ], result.value.map(&:type)
    end

    private

    def create_paid_placement(provider_fee_minor: nil)
      offer = Marketing::PlacementOffer.create!(
        code: "platform_journal_#{SecureRandom.hex(3)}", version: 1, daily_rate_minor: 10_000, currency: "ETB",
        minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
        surface: "public_discovery", terms_version: "v1", active: true,
        starts_at: 1.day.ago, ends_at: 30.days.from_now
      )
      starts_at = 1.hour.from_now.change(usec: 0)
      price_digest = Digest::SHA256.hexdigest("platform-price")
      placement = Marketing::FeaturedPlacement.create!(
        event: @event, organization_id: @event.organization_id, placement_offer: offer,
        status: "active", surface: "public_discovery", starts_at:, ends_at: starts_at + 24.hours,
        duration_seconds: 24.hours.to_i, offer_code: offer.code, offer_version: offer.version,
        daily_rate_minor: offer.daily_rate_minor, amount_minor: 10_000, currency: "ETB",
        terms_version: offer.terms_version, price_digest:,
        idempotency_key_digest: Digest::SHA256.hexdigest("platform-placement-#{SecureRandom.uuid}"),
        request_digest: Digest::SHA256.hexdigest("platform-request-#{SecureRandom.uuid}")
      )
      purchase = Orders::BillingPurchase.create!(
        organization_id: @event.organization_id, requested_by: core_users(:super_admin),
        kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: placement.id,
        currency: "ETB", amount_minor: 10_000, price_digest:, status: "paid",
        idempotency_key_digest: Digest::SHA256.hexdigest("platform-purchase-#{SecureRandom.uuid}"), expires_at: 30.minutes.from_now
      )
      payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 10_000, currency: "ETB", accepted_at: Time.current,
        succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
        provider_fee_minor:, provider_fee_currency: ("ETB" if provider_fee_minor),
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "platform-payment-#{SecureRandom.hex(4)}",
        settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
      )
      [ placement, purchase, payment ]
    end
  end
end
