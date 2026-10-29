# frozen_string_literal: true

require "test_helper"

module Events
  module Cancellation
    class ProcessPaymentGiftTest < ActiveSupport::TestCase
      include Events::CancellationTestHelpers
      include Orders::GiftPurchaseTestHelpers

      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:core_admin)
        setup_gift_purchase_context
      end

      test "event cancellation refunds an unclaimed gift to the original payer without requiring a ticket row" do
        payment = create_gift_payment
        cancellation = initiate_cancellation
        prepared = PrepareBatch.call(cancellation:)
        assert_predicate prepared, :success?, prepared.error&.message
        assert_equal "revoked", @gift_purchase.reload.status

        result = nil
        Orders::SubmitRefund.expects(:call).returns(Core::BaseService::Result.success(nil))
        result = ProcessPayment.call(cancellation:)

        assert_predicate result, :success?, result.error&.message
        refund = Orders::Refund.joins(:refund_items).find_by!(refund_items: { order_item_id: @gift_order_item.id })
        assert_equal payment.id, refund.payment_id
        assert_equal @gift_order.buyer_user_id, refund.payment.order.buyer_user_id
        assert_equal cancellation.id, refund.event_cancellation_id
        assert_nil refund.refund_items.sole.ticket_id
        assert_equal "created", refund.status
      end

      private

      def create_gift_payment
        Orders::Payment.create!(
          order: @gift_order,
          attempt_number: 1,
          provider: "chapa",
          payment_method: "telebirr",
          status: "succeeded",
          amount_minor: @gift_order.total_minor,
          currency: @gift_order.charge_currency,
          commercial_signature: @gift_order.commercial_signature,
          buyer_fee_minor: 0,
          organizer_fee_minor: 0,
          idempotency_key: "cancellation-gift-payment-#{SecureRandom.hex(5)}",
          provider_reference: "cancellation-gift-provider-#{SecureRandom.hex(4)}",
          accepted_at: Time.current,
          succeeded_at: Time.current,
          settlement_grace_minutes: 5,
          settlement_grace_expires_at: @gift_order.expires_at + 5.minutes
        )
      end
    end
  end
end
