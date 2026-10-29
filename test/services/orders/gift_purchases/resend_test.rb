# frozen_string_literal: true

require "test_helper"

module Orders
  module GiftPurchases
    class ResendTest < ActiveSupport::TestCase
      include Orders::GiftPurchaseTestHelpers

      setup do
        setup_gift_purchase_context
      end

      test "queues one audited resend for the payer and replays without another delivery request" do
        subject = lambda do
          Resend.call(
            gift_purchase: @gift_purchase,
            actor: @gift_purchaser,
            idempotency_key: "payer-resend-gift"
          )
        end

        result = subject.call
        replay = subject.call

        assert_predicate result, :success?, result.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert_equal 1, result.value.delivery_revision
        assert_equal 1, replay.value.delivery_revision
        assert_equal 1, Core::OutboxEvent.where(
          event_type: "orders.gift_purchase.delivery_requested",
          aggregate_id: @gift_purchase.id
        ).count
        assert_equal 1, Core::AuditLog.where(action: "orders.gift_purchase.delivery_resend_requested").count
      end

      test "rejects a resend by anyone other than the original payer" do
        result = Resend.call(
          gift_purchase: @gift_purchase,
          actor: core_users(:support),
          idempotency_key: "outsider-gift-resend"
        )

        assert_predicate result, :failure?
        assert_equal "gift_resend_forbidden", result.error.code
        assert_equal 0, @gift_purchase.delivery_revision
      end

      test "does not reopen or queue delivery for an expired gift" do
        @gift_purchase.update!(status: "expired", expired_at: @gift_purchase.expires_at)

        result = Resend.call(
          gift_purchase: @gift_purchase,
          actor: @gift_purchaser,
          idempotency_key: "expired-gift-resend"
        )

        assert_predicate result, :failure?
        assert_equal "gift_expired", result.error.code
        assert_equal "expired", @gift_purchase.reload.status
        assert_equal 0, Core::OutboxEvent.where(event_type: "orders.gift_purchase.delivery_requested").count
      end
    end
  end
end
