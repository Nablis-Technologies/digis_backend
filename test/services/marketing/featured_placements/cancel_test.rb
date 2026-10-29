# frozen_string_literal: true

require "digest"
require "test_helper"

module Marketing
  module FeaturedPlacements
    class CancelTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @offer = PlacementOffer.create!(
          code: "cancel_#{SecureRandom.hex(3)}", version: 1, daily_rate_minor: 10_000, currency: "ETB",
          minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          surface: "public_discovery", terms_version: "v1", status: "active",
          created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
          idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32),
          starts_at: 1.day.ago, ends_at: 30.days.from_now
        )
        @starts_at = 1.hour.from_now.change(usec: 0)
        @placement, @purchase, @payment = create_paid_placement(starts_at: @starts_at)
      end

      test "cancels immediately and creates a full refund for an unserved paid placement" do
        result = cancel

        assert_predicate result, :success?, result.error&.message
        assert_equal "cancelled", @placement.reload.status
        assert_equal 10_000, result.value.refund_amount_minor
        assert_equal "created", result.value.refund.status
        assert_equal result.value.refund.id, @placement.refund_id
        assert Core::OutboxEvent.exists?(event_type: "orders.refund.created", aggregate: result.value.refund)
      end

      test "refunds only the integer-floor unserved share after the placement has started" do
        result = cancel(at: @starts_at + 12.hours)

        assert_predicate result, :success?, result.error&.message
        assert_equal 5_000, result.value.refund_amount_minor
        assert_equal 5_000, result.value.refund.amount_minor
      end

      test "creates no provider refund when the interval has fully run" do
        result = cancel(at: @starts_at + 25.hours)

        assert_predicate result, :success?, result.error&.message
        assert_equal "cancelled", @placement.reload.status
        assert_equal 0, result.value.refund_amount_minor
        assert_nil result.value.refund
        assert_nil @placement.refund_id
        assert_empty Orders::Refund.where(billing_purchase_id: @purchase.id)
      end

      test "cancels an unpaid hold without creating a refund and late payment cannot activate it" do
        @purchase.update!(status: "pending_payment")
        @payment.update!(status: "processing", accepted_at: nil, succeeded_at: nil)

        result = cancel

        assert_predicate result, :success?, result.error&.message
        assert_equal "cancelled", @placement.reload.status
        assert_equal "cancelled", @purchase.reload.status
        assert_nil result.value.refund
      end

      test "same-key cancellation replay is idempotent and different users cannot cancel" do
        operation = -> { Cancel.call(placement: @placement, actor: @actor, idempotency_key: "cancel-idempotent") }
        assert_idempotent(operation, counter: -> { Orders::Refund.where(billing_purchase_id: @purchase.id).count })

        unauthorized = Cancel.call(
          placement: @placement, actor: core_users(:attendee), idempotency_key: "cancel-forbidden"
        )
        assert_predicate unauthorized, :failure?
        assert_equal "cancellation_forbidden", unauthorized.error.code
      end

      test "writes one audit fact for repeated cancellation commands" do
        operation = -> { cancel(key: "featured-placement-cancel-audit") }

        assert_audit_idempotent(
          operation, action: "marketing.featured_placement.cancelled",
          auditable_type: "Marketing::FeaturedPlacement", auditable_id: @placement.id
        )
      end

      private

      def cancel(at: Time.current, key: "featured-placement-cancel")
        Cancel.call(placement: @placement, actor: @actor, idempotency_key: key, at:)
      end

      def create_paid_placement(starts_at:)
        ends_at = starts_at + 24.hours
        price_digest = Digest::SHA256.hexdigest("cancel-price-#{SecureRandom.uuid}")
        placement = Marketing::FeaturedPlacement.create!(
          event: @event, organization_id: @event.organization_id, placement_offer: @offer,
          status: "scheduled", surface: "public_discovery", starts_at:, ends_at:, duration_seconds: 24.hours.to_i,
          offer_code: @offer.code, offer_version: @offer.version, daily_rate_minor: @offer.daily_rate_minor,
          amount_minor: 10_000, currency: "ETB", terms_version: @offer.terms_version, price_digest:,
          idempotency_key_digest: Digest::SHA256.hexdigest("cancel-placement-#{SecureRandom.uuid}"),
          request_digest: Digest::SHA256.hexdigest("cancel-request-#{SecureRandom.uuid}")
        )
        purchase = Orders::BillingPurchase.create!(
          organization_id: @event.organization_id, requested_by: @actor,
          kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: placement.id,
          currency: "ETB", amount_minor: 10_000, price_digest:, status: "paid",
          idempotency_key_digest: Digest::SHA256.hexdigest("cancel-purchase-#{SecureRandom.uuid}"),
          expires_at: 30.minutes.from_now
        )
        payment = Orders::Payment.create!(
          billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
          status: "succeeded", amount_minor: 10_000, currency: "ETB", accepted_at: Time.current,
          succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
          buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "cancel-payment-#{SecureRandom.hex(4)}",
          settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
        )
        [ placement, purchase, payment ]
      end
    end
  end
end
