# frozen_string_literal: true

require "digest"
require "test_helper"

module Marketing
  module OutboxHandlers
    class BillingPaymentLifecycleTest < ActiveSupport::TestCase
      Event = Data.define(:payload, :event_type)

      setup do
        @event = events_events(:ready_listing)
        @offer = PlacementOffer.create!(
          code: "lifecycle_discovery", version: 1, daily_rate_minor: 10_000, currency: "ETB",
          minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          surface: "public_discovery", terms_version: "v1", active: true,
          starts_at: 1.day.ago, ends_at: 30.days.from_now
        )
        starts_at = 1.hour.from_now.change(usec: 0)
        @placement = Marketing::FeaturedPlacement.create!(
          event: @event, organization_id: @event.organization_id, placement_offer: @offer,
          status: "pending_payment", surface: "public_discovery", starts_at:, ends_at: starts_at + 24.hours,
          duration_seconds: 24.hours.to_i, offer_code: @offer.code, offer_version: @offer.version,
          daily_rate_minor: @offer.daily_rate_minor, amount_minor: 10_000, currency: "ETB",
          terms_version: @offer.terms_version, price_digest: Digest::SHA256.hexdigest("lifecycle-price"),
          idempotency_key_digest: Digest::SHA256.hexdigest("lifecycle-placement"),
          request_digest: Digest::SHA256.hexdigest("lifecycle-request")
        )
        @purchase = Orders::BillingPurchase.create!(
          organization_id: @event.organization_id, requested_by: core_users(:super_admin),
          kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: @placement.id,
          currency: "ETB", amount_minor: 10_000, price_digest: @placement.price_digest,
          status: "failed", idempotency_key_digest: Digest::SHA256.hexdigest("lifecycle-purchase"),
          expires_at: 30.minutes.from_now
        )
        @payment = Orders::Payment.create!(
          billing_purchase: @purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
          status: "failed", amount_minor: 10_000, currency: "ETB",
          billing_purchase_price_digest: @purchase.price_digest, buyer_fee_minor: 0, organizer_fee_minor: 0,
          idempotency_key: "lifecycle-payment", settlement_grace_minutes: 5,
          settlement_grace_expires_at: @purchase.expires_at + 5.minutes
        )
      end

      test "marks the matching unpaid placement failed on a terminal payment failure" do
        result = BillingPaymentLifecycle.call(event: lifecycle_event("failed"))

        assert_predicate result, :success?, result.error&.message
        assert_equal "failed", @placement.reload.status
        assert_equal "failed", @placement.failure_code
      end

      test "no-ops on another allowlisted billing product" do
        event = Event.new(
          payload: { "source_type" => "Messaging::CreditTopUp", "source_id" => "missing" },
          event_type: "orders.billing_payment.failed"
        )
        result = BillingPaymentLifecycle.call(event:)

        assert_predicate result, :success?, result.error&.message
        assert_nil result.value
      end

      test "closes a placement on reversed billing payment evidence" do
        @purchase.update!(status: "reversed")
        @payment.update!(status: "reversed")

        result = BillingPaymentLifecycle.call(event: lifecycle_event("reversed"))

        assert_predicate result, :success?, result.error&.message
        assert_equal "failed", @placement.reload.status
        assert_equal "reversed", @placement.failure_code
      end

      private

      def lifecycle_event(outcome)
        Event.new(
          payload: {
            "source_type" => "Marketing::FeaturedPlacement", "source_id" => @placement.id,
            "billing_purchase_id" => @purchase.id, "payment_id" => @payment.id
          }, event_type: "orders.billing_payment.#{outcome}"
        )
      end
    end
  end
end
