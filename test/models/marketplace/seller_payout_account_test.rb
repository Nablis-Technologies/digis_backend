# frozen_string_literal: true

require "test_helper"

module Marketplace
  class SellerPayoutAccountTest < ActiveSupport::TestCase
    setup do
      @seller = core_users(:attendee)
      @verifier = core_users(:super_admin)
      @number = "1000000000001"
      @attributes = {
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_code: 128,
        account_number: @number,
        account_number_digest: Core::PayoutAccountDigest.call(
          namespace: @seller.id, account_number: @number
        ),
        holder_name: "Seller Holder",
        account_label: "Primary account"
      }
    end

    test "does not use account type as STI" do
      account = SellerPayoutAccount.new(@attributes)

      assert_predicate SellerPayoutAccount.inheritance_column, :blank?
      assert_equal "bank", account.type
    end

    test "exposes direct beneficiary accessors" do
      account = SellerPayoutAccount.new

      assert_respond_to account, :account_number
      assert_respond_to account, :account_number=
      assert_respond_to account, :holder_name
      assert_respond_to account, :holder_name=
    end

    test "encrypts beneficiary values at rest" do
      account = SellerPayoutAccount.create!(@attributes)

      assert_equal @number, account.account_number
      assert_equal "Seller Holder", account.holder_name
      stored = SellerPayoutAccount.connection.select_one(
        "SELECT account_number_ciphertext, holder_name_ciphertext " \
        "FROM marketplace_seller_payout_accounts WHERE id = '#{account.id}'"
      )
      refute_equal @number, stored.fetch("account_number_ciphertext")
      refute_equal "Seller Holder", stored.fetch("holder_name_ciphertext")
    end

    test "requires verification metadata for a verified default account" do
      account = SellerPayoutAccount.new(@attributes.merge(is_default: true, status: "verified"))

      assert_not account.valid?
      assert_includes account.errors.attribute_names, :verified_at
      assert_includes account.errors.attribute_names, :verification_source
    end

    test "requires an admin verifier for manual verification" do
      account = SellerPayoutAccount.new(
        @attributes.merge(
          status: "verified", verification_source: "manual", verified_at: Time.current
        )
      )

      assert_not account.valid?
      assert_includes account.errors.attribute_names, :verified_by
    end

    test "rejects a default account that is not verified" do
      account = SellerPayoutAccount.new(@attributes.merge(is_default: true))

      assert_not account.valid?
      assert_includes account.errors.attribute_names, :is_default
    end

    test "requires a positive bank code and an allowed lifecycle status" do
      account = SellerPayoutAccount.new(@attributes.merge(bank_code: 0, status: "unknown"))

      assert_not account.valid?
      assert_includes account.errors.attribute_names, :bank_code
      assert_includes account.errors.attribute_names, :status
    end

    test "rejects verification metadata on non-verified rows" do
      account = SellerPayoutAccount.new(
        @attributes.merge(status: "pending_verification", verified_at: Time.current,
          verification_source: "manual", verified_by: @verifier)
      )

      assert_not account.valid?
      assert_includes account.errors.attribute_names, :verified_at
      assert_includes account.errors.attribute_names, :verification_source
      assert_includes account.errors.attribute_names, :verified_by
    end

    test "does not expose credentials through ransackable attributes" do
      forbidden = %w[
        account_number account_number_ciphertext account_number_digest
        holder_name holder_name_ciphertext verified_by_id account_token
      ]

      assert_empty SellerPayoutAccount.ransackable_attributes & forbidden
    end
  end
end
