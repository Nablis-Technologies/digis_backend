# frozen_string_literal: true

require "test_helper"

module Orders
  module GiftPurchases
    class ResolveTest < ActiveSupport::TestCase
      include Orders::GiftPurchaseTestHelpers

      setup do
        setup_gift_purchase_context
      end

      test "resolves the bearer link to recipient-only gift details and attendee schemas" do
        _form, version, question = create_required_gift_form

        result = Resolve.call(gift_purchase_id: @gift_purchase.id, token: @gift_token)

        assert_predicate result, :success?, result.error&.message
        view = result.value
        assert_equal @gift_purchase.id, view.gift.fetch(:id)
        assert_equal "ready", view.gift.fetch(:status)
        assert_equal "A private gift note", view.gift.fetch(:note)
        assert_equal @gift_event.slug, view.event.fetch(:slug)
        assert_equal @gift_product.name, view.product.fetch(:name)
        assert_equal version.id, view.forms.sole.fetch(:id)
        assert_equal question.key, view.forms.sole.fetch(:questions).sole.fetch(:key)
        json = view.to_h.to_json
        refute_includes json, @gift_phone
        refute_includes json, @gift_token
        refute_includes json, @gift_purchase.recipient_user_id
      end

      test "rejects an incorrect bearer capability without disclosing gift existence" do
        result = Resolve.call(gift_purchase_id: @gift_purchase.id, token: "wrong-capability")

        assert_predicate result, :failure?
        assert_equal "gift_invalid", result.error.code
      end

      test "does not expose a gift before the payer's order is fulfilled" do
        @gift_purchase.update!(status: "pending_payment", ready_at: nil)

        result = Resolve.call(gift_purchase_id: @gift_purchase.id, token: @gift_token)

        assert_predicate result, :failure?
        assert_equal "gift_not_ready", result.error.code
      end

      test "treats the exact event end as expired even before the expiry worker runs" do
        result = Resolve.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          at: @gift_purchase.expires_at
        )

        assert_predicate result, :failure?
        assert_equal "gift_expired", result.error.code
      end
    end
  end
end
