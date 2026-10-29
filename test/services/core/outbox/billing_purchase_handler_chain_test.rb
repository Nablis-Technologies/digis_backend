# frozen_string_literal: true

require "digest"
require "test_helper"

module Core
  module Outbox
    class BillingPurchaseHandlerChainTest < ActiveSupport::TestCase
      setup do
        event = events_events(:ready_listing)
        offer = Marketing::PlacementOffer.create!(
          code: "handler_chain_#{SecureRandom.hex(3)}", version: 1, daily_rate_minor: 10_000,
          currency: "ETB", minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          surface: "public_discovery", terms_version: "v1", status: "active",
          created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
          idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32),
          starts_at: 1.day.ago, ends_at: 30.days.from_now
        )
        starts_at = 1.hour.from_now.change(usec: 0)
        price_digest = Digest::SHA256.hexdigest("billing-chain-price")
        @placement = Marketing::FeaturedPlacement.create!(
          event:, organization_id: event.organization_id, placement_offer: offer,
          status: "pending_payment", surface: "public_discovery", starts_at:, ends_at: starts_at + 24.hours,
          duration_seconds: 24.hours.to_i, offer_code: offer.code, offer_version: offer.version,
          daily_rate_minor: offer.daily_rate_minor, amount_minor: 10_000, currency: "ETB",
            terms_version: offer.terms_version, price_digest:,
          idempotency_key_digest: Digest::SHA256.hexdigest("billing-chain-placement"),
          request_digest: Digest::SHA256.hexdigest("billing-chain-request")
        )
        @purchase = Orders::BillingPurchase.create!(
          organization_id: event.organization_id, requested_by: core_users(:super_admin),
          kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: @placement.id,
          currency: "ETB", amount_minor: 10_000, price_digest:, status: "paid",
          idempotency_key_digest: Digest::SHA256.hexdigest("billing-chain-purchase"), expires_at: 30.minutes.from_now
        )
        @payment = Orders::Payment.create!(
          billing_purchase: @purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
          status: "succeeded", amount_minor: 10_000, currency: "ETB", accepted_at: Time.current,
          succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
          buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "billing-chain-payment",
          settlement_grace_minutes: 5, settlement_grace_expires_at: @purchase.expires_at + 5.minutes
        )
        publication = Core::Outbox::Publish.call(
          topic: "orders", event_type: "orders.billing_payment.accepted", aggregate: @payment,
          payload: {
            payment_id: @payment.id, billing_purchase_id: @purchase.id,
            source_type: @purchase.source_type, source_id: @placement.id,
            amount_minor: @purchase.amount_minor, currency: @purchase.currency
          },
          idempotency_key: "billing-chain-accepted-#{@payment.id}"
        )
        @outbox_event = publication.value
      end

      test "Marketing, Messaging, and Finance consumers compose idempotently for one billing event" do
        assert_equal @placement.id, @purchase.source_id
        assert_equal @purchase.amount_minor, @payment.amount_minor
        assert_equal @purchase.price_digest, @payment.billing_purchase_price_digest
        assert_equal @payment.id, @outbox_event.payload.fetch("payment_id")
        assert_equal @purchase.id, @outbox_event.payload.fetch("billing_purchase_id")
        assert_equal @placement.id, @outbox_event.payload.fetch("source_id")
        assert_equal @purchase.source_type, @outbox_event.payload.fetch("source_type")

        handler = Rails.application.config.x.outbox_handlers.fetch("orders.billing_payment.accepted")
        operation = -> { handler.call(@outbox_event) }

        assert_idempotent(operation, counter: -> {
          Finance::PlatformBillingEntry.where(payment_id: @payment.id).count +
            Core::AuditLog.where(action: "marketing.featured_placement.payment_accepted", auditable_id: @placement.id).count
        })
        result = operation.call

        assert_predicate result, :success?, result.error&.message
        assert_equal "scheduled", @placement.reload.status
        assert_equal 1, Finance::PlatformBillingEntry.where(
          payment_id: @payment.id, type: "featured_placement_charge"
        ).count
      end
    end
  end
end
