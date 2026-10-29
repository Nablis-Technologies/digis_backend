# frozen_string_literal: true

require "digest"
require "test_helper"

module Orders
  class BillingPurchaseTest < ActiveSupport::TestCase
    setup do
      @organization = organizations_organizations(:one)
      @requester = core_users(:super_admin)
    end

    test "accepts the typed featured placement purchase contract" do
      purchase = build_purchase

      assert_predicate purchase, :valid?, purchase.errors.full_messages.join(", ")
      assert_equal "featured_placement", purchase.kind
      assert_equal "Marketing::FeaturedPlacement", purchase.source_type
    end

    test "rejects an unregistered billing product source" do
      purchase = build_purchase(source_type: "Unknown::Product")

      assert_not purchase.valid?
      assert_includes purchase.errors.attribute_names, :source_type
    end

    private

    def build_purchase(source_type: "Marketing::FeaturedPlacement")
      Orders::BillingPurchase.new(
        organization: @organization, requested_by: @requester,
        kind: "featured_placement", source_type:, source_id: SecureRandom.uuid,
        currency: "ETB", amount_minor: 10_000, price_digest: Digest::SHA256.hexdigest("billing-model-price"),
        status: "pending_payment", idempotency_key_digest: Digest::SHA256.hexdigest("billing-model-key"),
        expires_at: 30.minutes.from_now
      )
    end
  end
end
