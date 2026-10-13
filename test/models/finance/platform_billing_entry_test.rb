# frozen_string_literal: true

require "test_helper"

module Finance
  class PlatformBillingEntryTest < ActiveSupport::TestCase
    test "allows only explicit signed platform entry shapes" do
      charge = PlatformBillingEntry.new(
        type: "featured_placement_charge", amount_minor: 100, currency: "ETB", idempotency_key: "a" * 64
      )
      fee = PlatformBillingEntry.new(
        type: "provider_fee", amount_minor: -5, currency: "ETB", idempotency_key: "b" * 64
      )
      refund = PlatformBillingEntry.new(
        type: "featured_placement_refund", amount_minor: -50, refund_id: SecureRandom.uuid,
        currency: "ETB", idempotency_key: "c" * 64
      )

      assert_includes charge.errors.attribute_names, :billing_purchase if !charge.valid?
      assert_equal "featured_placement_charge", charge.type
      assert_equal "provider_fee", fee.type
      assert_equal "featured_placement_refund", refund.type
    end

    test "rejects zero, unsigned fees, and noncanonical currency" do
      entry = PlatformBillingEntry.new(
        type: "provider_fee", amount_minor: 0, currency: "USD", idempotency_key: "d" * 64
      )

      assert_not entry.valid?
      assert_includes entry.errors.attribute_names, :amount_minor
      assert_includes entry.errors.attribute_names, :currency
    end

    test "rejects a journal entry whose payment belongs to a different billing purchase" do
      purchase = Orders::BillingPurchase.new(
        id: SecureRandom.uuid, source_type: "Marketing::FeaturedPlacement"
      )
      payment = Orders::Payment.new(id: SecureRandom.uuid, billing_purchase_id: SecureRandom.uuid)
      entry = PlatformBillingEntry.new(
        billing_purchase: purchase, payment:, type: "featured_placement_charge",
        amount_minor: 100, currency: "ETB", idempotency_key: "e" * 64
      )

      assert_not entry.valid?
      assert_includes entry.errors.attribute_names, :billing_purchase_id
    end

    test "does not permit Ransack to query arbitrary associations" do
      assert_equal %w[billing_purchase payment refund], PlatformBillingEntry.ransackable_associations
      refute_includes PlatformBillingEntry.ransackable_attributes, "provider_payload"
    end
  end
end
