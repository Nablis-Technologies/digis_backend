# frozen_string_literal: true

require "digest"
require "test_helper"

module Marketing
  module OutboxHandlers
    class EventCancelledTest < ActiveSupport::TestCase
      Event = Data.define(:payload, :event_type)

      setup do
        @event = events_events(:ready_listing)
        offer = Marketing::PlacementOffer.create!(
          code: "event_cancel_#{SecureRandom.hex(3)}", version: 1, daily_rate_minor: 10_000,
          currency: "ETB", minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          surface: "public_discovery", terms_version: "v1", status: "active",
          created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
          idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32),
          starts_at: 1.day.ago, ends_at: 30.days.from_now
        )
        starts_at = 1.hour.from_now.change(usec: 0)
        price_digest = Digest::SHA256.hexdigest("event-cancel-price")
        @placement = Marketing::FeaturedPlacement.create!(
          event: @event, organization_id: @event.organization_id, placement_offer: offer,
          status: "scheduled", surface: "public_discovery", starts_at:, ends_at: starts_at + 24.hours,
          duration_seconds: 24.hours.to_i, offer_code: offer.code, offer_version: offer.version,
          daily_rate_minor: offer.daily_rate_minor, amount_minor: 10_000, currency: "ETB",
          terms_version: offer.terms_version, price_digest:,
          idempotency_key_digest: Digest::SHA256.hexdigest("event-cancel-placement"),
          request_digest: Digest::SHA256.hexdigest("event-cancel-request")
        )
        purchase = Orders::BillingPurchase.create!(
          organization_id: @event.organization_id, requested_by: core_users(:super_admin),
          kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: @placement.id,
          currency: "ETB", amount_minor: 10_000, price_digest:, status: "paid",
          idempotency_key_digest: Digest::SHA256.hexdigest("event-cancel-purchase"), expires_at: 30.minutes.from_now
        )
        Orders::Payment.create!(
          billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
          status: "succeeded", amount_minor: 10_000, currency: "ETB", accepted_at: Time.current,
          succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
          buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "event-cancel-payment",
          settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
        )
      end

      test "stops serving and creates the cancellation refund obligation idempotently" do
        event = Event.new(payload: { "event_id" => @event.id }, event_type: "events.cancellation_initiated")

        first = EventCancelled.call(event:)
        replay = EventCancelled.call(event:)

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert_equal "cancelled", @placement.reload.status
        refund = Orders::Refund.find_by!(billing_purchase_id: Orders::BillingPurchase.find_by!(source_id: @placement.id).id)
        assert_equal "event_cancelled", refund.reason_code
        assert_equal "created", refund.status
        assert_equal 1, Orders::Refund.where(billing_purchase_id: refund.billing_purchase_id).count
      end
    end
  end
end
