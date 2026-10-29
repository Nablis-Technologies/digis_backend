# frozen_string_literal: true

require "digest"
require "test_helper"

module Finance
  class ReconcilePlatformBillingEntriesTest < ActiveSupport::TestCase
    include PerformanceQueryHelpers

    setup do
      @event = events_events(:ready_listing)
      @placement, @purchase, @payment = create_paid_placement
    end

    test "recovers accepted charges and succeeded refunds without double posting" do
      first = ReconcilePlatformBillingEntries.call
      refund = Orders::Refund.create!(
        payment: @payment, billing_purchase: @purchase, type: "billing_purchase_refund",
        idempotency_key: Digest::SHA256.hexdigest("reconcile-platform-refund"), amount_minor: 1_500,
        currency: "ETB", status: "succeeded", reason_code: "featured_placement_cancelled"
      )
      second = ReconcilePlatformBillingEntries.call
      replay = ReconcilePlatformBillingEntries.call

      assert_predicate first, :success?, first.error&.message
      assert_equal 1, first.value.charges_reconciled
      assert_predicate second, :success?, second.error&.message
      assert_equal 1, second.value.refunds_reconciled
      assert_predicate replay, :success?, replay.error&.message
      assert_equal 0, replay.value.charges_reconciled
      assert_equal 0, replay.value.refunds_reconciled
      assert_equal 1, PlatformBillingEntry.where(type: "featured_placement_charge", payment_id: @payment.id).count
      assert_equal 1, PlatformBillingEntry.where(type: "featured_placement_refund", refund_id: refund.id).count
    end

    test "respects the bounded batch limit" do
      create_paid_placement
      result = ReconcilePlatformBillingEntries.call(limit: 1)

      assert_predicate result, :success?, result.error&.message
      assert_equal 1, result.value.charges_reconciled
      assert_equal 1, PlatformBillingEntry.where(type: "featured_placement_charge").count
    end

    test "batch loads billing purchases while reconciling accepted charges" do
      Prosopite.pause { 2.times { create_paid_placement } }

      statements = Prosopite.pause do
        capture_database_queries do
          result = ReconcilePlatformBillingEntries.call
          assert_predicate result, :success?, result.error&.message
        end
      end
      purchase_reads = statements.count do |sql|
        sql.match?(/SELECT\s+"orders_billing_purchases"\.\*\s+FROM\s+"orders_billing_purchases"/i) &&
          !sql.match?(/FOR UPDATE/i)
      end

      assert_equal 1, purchase_reads,
        "expected one batch read for billing purchases"
      assert_equal 0, source_scope_exists_reads(statements),
        "expected source integrity to use the locked billing associations"
      assert_equal 3, PlatformBillingEntry.where(type: "featured_placement_charge").count
    end

    test "batch loads refund payments and purchases before posting the refund facts" do
      billing_records = [ [ @purchase, @payment ] ]
      Prosopite.pause do
        2.times do
          _placement, purchase, payment = create_paid_placement
          billing_records << [ purchase, payment ]
        end
      end
      first_reconciliation = Prosopite.pause { ReconcilePlatformBillingEntries.call }
      assert_predicate first_reconciliation, :success?
      Prosopite.pause do
        billing_records.each_with_index do |(purchase, payment), index|
          Orders::Refund.create!(
            payment:, billing_purchase: purchase, type: "billing_purchase_refund",
            idempotency_key: Digest::SHA256.hexdigest("reconcile-batch-refund-#{index}-#{SecureRandom.uuid}"),
            amount_minor: 1_500, currency: "ETB", status: "succeeded",
            reason_code: "featured_placement_cancelled"
          )
        end
      end

      statements = Prosopite.pause do
        capture_database_queries do
          result = ReconcilePlatformBillingEntries.call
          assert_predicate result, :success?, result.error&.message
        end
      end
      payment_reads = full_row_reads(statements, "orders_payments")
      purchase_reads = full_row_reads(statements, "orders_billing_purchases")

      assert_equal 2, payment_reads, "expected one empty charge scan and one batched refund-payment read"
      assert_equal 1, purchase_reads,
        "expected one batched refund-purchase read"
      assert_equal 0, source_scope_exists_reads(statements),
        "expected source integrity to use the locked billing associations"
      assert_equal 3, PlatformBillingEntry.where(type: "featured_placement_refund").count
    end

    private

    def full_row_reads(statements, table)
      statements.count do |sql|
        sql.match?(/SELECT\s+"#{table}"\.\*\s+FROM\s+"#{table}"/i) && !sql.match?(/FOR UPDATE/i)
      end
    end

    def source_scope_exists_reads(statements)
      statements.count do |sql|
        sql.match?(/\ASELECT 1 AS one FROM "(?:orders_billing_purchases|orders_payments|orders_refunds)"/i)
      end
    end

    def create_paid_placement
      offer = Marketing::PlacementOffer.create!(
        code: "reconcile_#{SecureRandom.hex(3)}", version: 1, daily_rate_minor: 10_000, currency: "ETB",
        minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
        surface: "public_discovery", terms_version: "v1", status: "active",
        created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
        idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32),
        starts_at: 1.day.ago, ends_at: 30.days.from_now
      )
      starts_at = 1.hour.from_now.change(usec: 0)
      price_digest = Digest::SHA256.hexdigest("reconcile-price-#{SecureRandom.uuid}")
      placement = Marketing::FeaturedPlacement.create!(
        event: @event, organization_id: @event.organization_id, placement_offer: offer,
        status: "active", surface: "public_discovery", starts_at:, ends_at: starts_at + 24.hours,
        duration_seconds: 24.hours.to_i, offer_code: offer.code, offer_version: offer.version,
        daily_rate_minor: offer.daily_rate_minor, amount_minor: 10_000, currency: "ETB",
        terms_version: offer.terms_version, price_digest:,
        idempotency_key_digest: Digest::SHA256.hexdigest("reconcile-placement-#{SecureRandom.uuid}"),
        request_digest: Digest::SHA256.hexdigest("reconcile-request-#{SecureRandom.uuid}")
      )
      purchase = Orders::BillingPurchase.create!(
        organization_id: @event.organization_id, requested_by: core_users(:super_admin),
        kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: placement.id,
        currency: "ETB", amount_minor: 10_000, price_digest:, status: "paid",
        idempotency_key_digest: Digest::SHA256.hexdigest("reconcile-purchase-#{SecureRandom.uuid}"),
        expires_at: 30.minutes.from_now
      )
      payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 10_000, currency: "ETB", accepted_at: Time.current,
        succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "reconcile-payment-#{SecureRandom.hex(4)}",
        settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
      )
      [ placement, purchase, payment ]
    end
  end
end
