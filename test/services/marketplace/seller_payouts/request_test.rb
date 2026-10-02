# frozen_string_literal: true

require "test_helper"

module Marketplace
  module SellerPayouts
    class RequestTest < ActiveSupport::TestCase
      include Marketplace::SellerPayoutTestHelpers

      setup do
        setup_seller_payout_context
        @account.update!(is_default: true)
        create_seller_ledger_entry(amount_minor: 10_000)
      end

      test "rolls back payout reservation and audit when dispatch intent cannot be published" do
        error = Core::BusinessError.new("outbox unavailable", code: "outbox_unavailable", status: :service_unavailable)
        Core::Outbox::Publish.expects(:call).once.returns(Core::BaseService::Result.failure(error))

        result = Request.call(
          seller: @seller,
          currency: "ETB",
          idempotency_key: "seller-payout-outbox-failure",
          at: @now
        )

        assert_predicate result, :failure?
        assert_equal "outbox_unavailable", result.error.code
        assert_empty SellerPayout.where(seller_user: @seller)
        assert_empty SellerPayoutAllocation.joins(:payout)
          .where(marketplace_seller_payouts: { seller_user_id: @seller.id })
        assert_empty Core::AuditLog.where(action: "marketplace.seller_payout.requested")
        assert_empty Core::OutboxEvent.where(event_type: "marketplace.seller_payout.requested")
      end
    end
  end
end
