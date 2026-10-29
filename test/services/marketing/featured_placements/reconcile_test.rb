# frozen_string_literal: true

require "digest"
require "test_helper"

module Marketing
  module FeaturedPlacements
    class ReconcileTest < ActiveSupport::TestCase
      include PerformanceQueryHelpers

      setup do
        @event = events_events(:ready_listing)
        @offer = PlacementOffer.create!(
          code: "reconcile_placement", version: 1, daily_rate_minor: 10_000, currency: "ETB",
          minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          surface: "public_discovery", terms_version: "v1", status: "active",
          created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
          idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32),
          starts_at: 1.day.ago, ends_at: 30.days.from_now
        )
      end

      test "recovers an accepted payment whose outbox activation was missed" do
        make_public_event_eligible
        _placement, purchase, = create_billing_context(
          placement_status: "pending_payment", purchase_status: "paid", payment_status: "succeeded",
          accepted_at: Time.current, starts_at: 1.hour.from_now, ends_at: 25.hours.from_now
        )

        result = Reconcile.call

        assert_predicate result, :success?, result.error&.message
        assert_equal 1, result.value.payments_recovered
        assert_equal "scheduled", Marketing::FeaturedPlacement.find_by!(id: purchase.source_id).status
      end

      test "batch loads purchase and payment evidence for accepted-placement recovery" do
        make_public_event_eligible
        Prosopite.pause do
          3.times do |index|
            create_billing_context(
              placement_status: "pending_payment", purchase_status: "paid", payment_status: "succeeded",
              accepted_at: Time.current, starts_at: (index + 1).hours.from_now,
              ends_at: (index + 25).hours.from_now
            )
          end
        end

        statements = Prosopite.pause do
          capture_database_queries do
            result = Reconcile.call
            assert_predicate result, :success?, result.error&.message
            assert_equal 3, result.value.payments_recovered
          end
        end
        payment_reads = full_row_reads(statements, "orders_payments")
        purchase_reads = full_row_reads(statements, "orders_billing_purchases")

        assert_equal 1, payment_reads,
          "expected one batched payment-evidence read"
        assert_equal 1, purchase_reads,
          "expected one batched billing-purchase read"
      end

      test "fails closed and releases an expired unpaid placement reservation" do
        placement, purchase, = create_billing_context(
          placement_status: "pending_payment", purchase_status: "pending_payment", payment_status: nil,
          accepted_at: nil, starts_at: 1.hour.from_now, ends_at: 25.hours.from_now,
          expires_at: 1.minute.ago
        )

        result = Reconcile.call

        assert_predicate result, :success?, result.error&.message
        assert_equal 1, result.value.expired
        assert_equal "failed", placement.reload.status
        assert_equal "checkout_expired", placement.failure_code
        assert_equal "failed", purchase.reload.status
      end

      test "completes elapsed placements without reopening their serving window" do
        placement, = create_billing_context(
          placement_status: "active", purchase_status: "paid", payment_status: "succeeded",
          accepted_at: Time.current, starts_at: 3.days.ago, ends_at: 2.days.ago
        )

        result = Reconcile.call

        assert_predicate result, :success?, result.error&.message
        assert_equal 1, result.value.completed
        assert_equal "completed", placement.reload.status
        assert placement.completed_at
      end

      test "cancels and refunds the unserved balance when an event loses public eligibility" do
        placement, purchase, = create_billing_context(
          placement_status: "scheduled", purchase_status: "paid", payment_status: "succeeded",
          accepted_at: Time.current, starts_at: 1.hour.from_now, ends_at: 25.hours.from_now
        )

        result = Reconcile.call

        assert_predicate result, :success?, result.error&.message
        assert_equal 1, result.value.ineligible_cancelled
        assert_equal "cancelled", placement.reload.status
        refund = Orders::Refund.find_by!(billing_purchase_id: purchase.id)
        assert_equal 10_000, refund.amount_minor
        assert_equal "featured_placement_cancelled", refund.reason_code
      end

      private

      def full_row_reads(statements, table)
        statements.count do |sql|
          sql.match?(/SELECT\s+"#{table}"\.\*\s+FROM\s+"#{table}"/i) && !sql.match?(/FOR UPDATE/i)
        end
      end

      def make_public_event_eligible
        Core::Review.create!(reviewable: @event.organization, context: "verification", status: "approved")
        make_publishable(@event)
        Events::EventDate.where(event_id: @event.id).update_all(
          status: "scheduled", starts_at: 52.hours.from_now, ends_at: 54.hours.from_now
        )
        @event.event_setting.update!(config: { event_type: "rsvp", public_guest_limit: 10 })
        Events::Publish.call(event: @event, actor: core_users(:super_admin), idempotency_key: SecureRandom.uuid)
        product = Catalog::Products::CreateDraft.call(
          event: @event, actor: core_users(:super_admin),
          product_attributes: { name: "Reconcile RSVP", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
          },
          price_attributes: { currency: "ETB", amount_minor: 0, active_from: 1.hour.ago },
          inventory_configuration: { mode: "unlimited" }
        ).value
        product.product_accesses.create!(
          event_date_id: Events::EventDate.where(event_id: @event.id, status: "scheduled").pick(:id),
          type: "venue", usage_limit: nil
        )
        Catalog::Products::Activate.call(product:, actor: core_users(:super_admin))
      end

      def create_billing_context(placement_status:, purchase_status:, payment_status:, accepted_at:, starts_at:, ends_at:,
        expires_at: 30.minutes.from_now)
        duration = (ends_at - starts_at).to_i
        price_digest = Digest::SHA256.hexdigest("reconcile-placement-#{SecureRandom.uuid}")
        placement = Marketing::FeaturedPlacement.create!(
          event: @event, organization_id: @event.organization_id, placement_offer: @offer,
          status: placement_status, surface: "public_discovery", starts_at:, ends_at:, duration_seconds: duration,
          offer_code: @offer.code, offer_version: @offer.version, daily_rate_minor: @offer.daily_rate_minor,
          amount_minor: (@offer.daily_rate_minor * duration + 86_399) / 86_400, currency: "ETB",
          terms_version: @offer.terms_version, price_digest:,
          idempotency_key_digest: Digest::SHA256.hexdigest("reconcile-idem-#{SecureRandom.uuid}"),
          request_digest: Digest::SHA256.hexdigest("reconcile-request-#{SecureRandom.uuid}")
        )
        purchase = Orders::BillingPurchase.create!(
          organization_id: @event.organization_id, requested_by: core_users(:super_admin),
          kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: placement.id,
          currency: "ETB", amount_minor: placement.amount_minor, price_digest:, status: purchase_status,
          idempotency_key_digest: Digest::SHA256.hexdigest("reconcile-purchase-#{SecureRandom.uuid}"), expires_at:
        )
        payment = if payment_status
          Orders::Payment.create!(
            billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
            status: payment_status, amount_minor: purchase.amount_minor, currency: purchase.currency,
            accepted_at:, succeeded_at: accepted_at, billing_purchase_price_digest: purchase.price_digest,
            buyer_fee_minor: 0, organizer_fee_minor: 0,
            idempotency_key: "reconcile-payment-#{SecureRandom.hex(4)}",
            settlement_grace_minutes: 5, settlement_grace_expires_at: expires_at + 5.minutes
          )
        end
        [ placement, purchase, payment ]
      end
    end
  end
end
