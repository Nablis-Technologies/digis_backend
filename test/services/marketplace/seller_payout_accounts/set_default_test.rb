# frozen_string_literal: true

require "test_helper"

module Marketplace
  module SellerPayoutAccounts
    class SetDefaultTest < ActiveSupport::TestCase
      include Marketplace::SellerPayoutTestHelpers

      setup do
        setup_seller_payout_context
        @account.update!(is_default: true)
        @replacement = create_payout_account(
          status: "verified", verified_at: @now, account_number: "1000000000010"
        )
      end

      test "selects one verified account as the seller default" do
        result = SetDefault.call(
          account: @replacement,
          actor: @seller,
          idempotency_key: "seller-account-default-1"
        )

        assert_predicate result, :success?, result.error&.message
        assert result.value.is_default
        assert_not @account.reload.is_default
        assert_equal 1, SellerPayoutAccount.where(user: @seller, is_default: true).count
      end

      test "rejects a pending account" do
        pending = create_payout_account(account_number: "1000000000011")
        result = SetDefault.call(
          account: pending,
          actor: @seller,
          idempotency_key: "seller-account-default-2"
        )

        assert_predicate result, :failure?
        assert_equal "payout_account_not_verifiable", result.error.code
      end

      test "rejects another seller" do
        result = SetDefault.call(
          account: @replacement,
          actor: core_users(:support),
          idempotency_key: "seller-account-default-3"
        )

        assert_predicate result, :failure?
        assert_equal "unauthorized", result.error.code
      end

      test "replays a default selection without another audit row" do
        subject = -> {
          SetDefault.call(
            account: @replacement,
            actor: @seller,
            idempotency_key: "seller-account-default-4"
          )
        }

        assert_audit_idempotent(
          subject,
          action: "marketplace.seller_payout_account.default_selected",
          auditable_type: SellerPayoutAccount.name,
          auditable_id: @replacement.id
        )
      end
    end
  end
end
