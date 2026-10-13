# frozen_string_literal: true

require "digest"
require "test_helper"

module Admin
  module Orders
    class RefundResolutionsTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers

      setup do
        event = events_events(:ready_listing)
        offer = Marketing::PlacementOffer.create!(
          code: "admin_refund_#{SecureRandom.hex(3)}", version: 1, daily_rate_minor: 10_000,
          currency: "ETB", minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          surface: "public_discovery", terms_version: "v1", active: true,
          starts_at: 1.day.ago, ends_at: 30.days.from_now
        )
        starts_at = 1.hour.from_now.change(usec: 0)
        price_digest = Digest::SHA256.hexdigest("admin-manual-price")
        placement = Marketing::FeaturedPlacement.create!(
          event:, organization_id: event.organization_id, placement_offer: offer,
          status: "cancelled", surface: "public_discovery", starts_at:, ends_at: starts_at + 24.hours,
          duration_seconds: 24.hours.to_i, offer_code: offer.code, offer_version: offer.version,
          daily_rate_minor: offer.daily_rate_minor, amount_minor: 10_000, currency: "ETB",
          terms_version: offer.terms_version, price_digest:,
          idempotency_key_digest: Digest::SHA256.hexdigest("admin-manual-placement"),
          request_digest: Digest::SHA256.hexdigest("admin-manual-request")
        )
        purchase = ::Orders::BillingPurchase.create!(
          organization_id: event.organization_id, requested_by: core_users(:super_admin),
          kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: placement.id,
          currency: "ETB", amount_minor: 10_000, price_digest:, status: "paid",
          idempotency_key_digest: Digest::SHA256.hexdigest("admin-manual-purchase"), expires_at: 30.minutes.from_now
        )
        payment = ::Orders::Payment.create!(
          billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
          status: "succeeded", amount_minor: 10_000, currency: "ETB", accepted_at: Time.current,
          succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
          buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "admin-manual-payment",
          settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
        )
        @refund = ::Orders::Refund.create!(
          payment:, billing_purchase: purchase, type: "billing_purchase_refund",
          idempotency_key: Digest::SHA256.hexdigest("admin-manual-refund"), amount_minor: 5_000,
          currency: "ETB", status: "manual_review", reason_code: "featured_placement_cancelled",
          pending_reason: "provider_partial_refund_unsupported"
        )
      end

      test "requires an idempotency key and a super-admin to resolve a manual refund" do
        path = "/admin/orders/refunds/#{@refund.id}/resolve_manual"
        body = { resolution: { reason: "Confirmed in Chapa test dashboard", evidence_reference: "CHAPA-REF-555" } }

        post path, params: body, headers: admin_headers, as: :json
        assert_response :bad_request
        assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
        assert_equal "manual_review", @refund.reload.status

        post path, params: body, headers: user_headers.merge("Idempotency-Key" => "manual-refund-user"), as: :json
        assert_response :forbidden
        assert_equal "manual_review", @refund.reload.status
      end

      test "resolves only after operator attestation and never returns the evidence reference" do
        post "/admin/orders/refunds/#{@refund.id}/resolve_manual",
          params: { resolution: {
            reason: "Confirmed in Chapa test dashboard", evidence_reference: "CHAPA-REF-555"
          } },
          headers: admin_headers.merge("Idempotency-Key" => "manual-refund-admin"), as: :json

        assert_response :success
        data = response.parsed_body.fetch("data")
        assert_equal @refund.id, data.fetch("id")
        assert_equal "succeeded", data.fetch("status")
        assert_not data.key?("manual_evidence_reference")
        assert_not data.key?("manual_resolution_reason")
        assert_equal 1, Core::OutboxEvent.where(event_type: "orders.refund.succeeded", aggregate: @refund).count
      end
    end
  end
end
