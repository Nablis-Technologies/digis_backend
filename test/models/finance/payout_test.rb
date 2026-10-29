# frozen_string_literal: true

require "test_helper"

module Finance
  class PayoutTest < ActiveSupport::TestCase
    test "belongs to the destination snapshot used for the payout" do
      association = Payout.reflect_on_association(:payout_account)

      assert_equal :belongs_to, association.macro
      assert_equal PayoutAccount, association.klass
    end

    test "requires a payout destination" do
      payout = Payout.new(
        organization: organizations_organizations(:one),
        currency: "ETB",
        amount_minor: 1_000,
        status: "pending",
        idempotency_key: "payout-account-required",
        requested_at: Time.current
      )

      assert_not payout.valid?
      assert_includes payout.errors.attribute_names, :payout_account
    end
  end
end
