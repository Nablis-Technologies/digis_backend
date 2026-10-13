# frozen_string_literal: true

require "digest"
require "test_helper"

module Marketing
  module OutboxHandlers
    class BillingPaymentAcceptedTest < ActiveSupport::TestCase
      Event = Data.define(:payload, :event_type)

      setup do
        @event = events_events(:ready_listing)
        @offer = PlacementOffer.create!(
          code: "handler_discovery", version: 1, daily_rate_minor: 10_000, currency: "ETB",
          minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          surface: "public_discovery", terms_version: "v1", active: true,
          starts_at: 1.day.ago, ends_at: 30.days.from_now
        )
        @starts_at = 1.hour.from_now.change(usec: 0)
        @ends_at = @starts_at + 24.hours
        @placement = create_placement
        @purchase = Orders::BillingPurchase.create!(
          organization_id: @event.organization_id, requested_by: core_users(:super_admin),
          kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: @placement.id,
          currency: "ETB", amount_minor: @placement.amount_minor, price_digest: @placement.price_digest,
          status: "paid", idempotency_key_digest: Digest::SHA256.hexdigest("accepted-purchase"),
          expires_at: 30.minutes.from_now
        )
        @payment = Orders::Payment.create!(
          billing_purchase: @purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
          status: "succeeded", amount_minor: @purchase.amount_minor, currency: @purchase.currency,
          billing_purchase_price_digest: @purchase.price_digest, accepted_at: Time.current,
          succeeded_at: Time.current, buyer_fee_minor: 0, organizer_fee_minor: 0,
          idempotency_key: "accepted-feature-payment", settlement_grace_minutes: 5,
          settlement_grace_expires_at: @purchase.expires_at + 5.minutes
        )
      end

      test "schedules only a paid placement with matching accepted payment evidence" do
        operation = -> { BillingPaymentAccepted.call(event: accepted_event) }
        assert_audit_idempotent(
          operation, action: "marketing.featured_placement.payment_accepted",
          auditable_type: "Marketing::FeaturedPlacement", auditable_id: @placement.id
        )
        result = operation.call

        assert_predicate result, :success?, result.error&.message
        assert_equal "scheduled", @placement.reload.status
        assert_equal 1, Core::AuditLog.where(action: "marketing.featured_placement.payment_accepted").count
      end

      test "marks a paid placement active when its start time has arrived" do
        result = BillingPaymentAccepted.call(event: accepted_event, at: @starts_at + 1.hour)

        assert_predicate result, :success?, result.error&.message
        assert_equal "active", @placement.reload.status
      end

      test "no-ops on a different allowlisted billing product" do
        event = Event.new(
          payload: { "source_type" => "Messaging::CreditTopUp", "source_id" => "missing" },
          event_type: "orders.billing_payment.accepted"
        )

        result = BillingPaymentAccepted.call(event:)

        assert_predicate result, :success?, result.error&.message
        assert_nil result.value
      end

      test "rejects accepted-payment evidence that does not match the immutable price snapshot" do
        event = accepted_event
        event = Event.new(
          payload: event.payload.merge("billing_purchase_id" => SecureRandom.uuid),
          event_type: event.event_type
        )

        result = BillingPaymentAccepted.call(event:)

        assert_predicate result, :failure?
        assert_equal "billing_payment_mismatch", result.error.code
        assert_equal "pending_payment", @placement.reload.status
      end

      private

      def accepted_event
        Event.new(
          payload: {
            "source_type" => "Marketing::FeaturedPlacement", "source_id" => @placement.id,
            "billing_purchase_id" => @purchase.id, "payment_id" => @payment.id
          }, event_type: "orders.billing_payment.accepted"
        )
      end

      def create_placement
        Marketing::FeaturedPlacement.create!(
          event: @event, organization_id: @event.organization_id, placement_offer: @offer,
          status: "pending_payment", surface: "public_discovery", starts_at: @starts_at, ends_at: @ends_at,
          duration_seconds: 24.hours.to_i, offer_code: @offer.code, offer_version: @offer.version,
          daily_rate_minor: @offer.daily_rate_minor, amount_minor: 10_000, currency: "ETB",
          terms_version: @offer.terms_version, price_digest: Digest::SHA256.hexdigest("accepted-price"),
          idempotency_key_digest: Digest::SHA256.hexdigest("accepted-placement"),
          request_digest: Digest::SHA256.hexdigest("accepted-request")
        )
      end
    end
  end
end
