# frozen_string_literal: true

require "test_helper"

module Finance
  class PayoutAccountTest < ActiveSupport::TestCase
    setup do
      @organization = organizations_organizations(:one)
      @attributes = {
        organization: @organization,
        type: "bank",
        provider: "chapa",
        bank_code: 128,
        account_number: "1000000000001",
        account_name: "Digis Organizer",
        account_label: "Primary account",
        account_number_digest: Core::KeyedDigest.digest(
          namespace: @organization.id, value: "1000000000001"
        )
      }
    end

    test "does not use account type as STI" do
      account = PayoutAccount.new(@attributes)

      assert_predicate PayoutAccount.inheritance_column, :blank?
      assert_equal "bank", account.type
    end

    test "encrypts beneficiary values at rest" do
      account = PayoutAccount.new(@attributes)
      account.save!

      assert_equal "1000000000001", account.account_number
      assert_equal "Digis Organizer", account.account_name
      stored = PayoutAccount.connection.select_one(
        "SELECT account_number_ciphertext, account_name_ciphertext " \
        "FROM finance_payout_accounts WHERE id = '#{account.id}'"
      )
      refute_equal "1000000000001", stored.fetch("account_number_ciphertext")
      refute_equal "Digis Organizer", stored.fetch("account_name_ciphertext")
    end

    test "requires verification metadata for a verified default account" do
      account = PayoutAccount.new(@attributes.merge(is_default: true, status: "verified"))

      assert_not account.valid?
      assert_includes account.errors.attribute_names, :verified_at
      assert_includes account.errors.attribute_names, :verification_source
    end

    test "rejects a default account that is not verified" do
      account = PayoutAccount.new(@attributes.merge(is_default: true))

      assert_not account.valid?
      assert_includes account.errors.attribute_names, :is_default
    end

    test "requires a positive bank code and an allowed lifecycle status" do
      account = PayoutAccount.new(@attributes.merge(bank_code: 0, status: "unknown"))

      assert_not account.valid?
      assert_includes account.errors.attribute_names, :bank_code
      assert_includes account.errors.attribute_names, :status
    end

    test "requires an owning organization" do
      account = PayoutAccount.new(@attributes.merge(organization: nil))

      assert_not account.valid?
      assert_includes account.errors.attribute_names, :organization
    end
  end
end
