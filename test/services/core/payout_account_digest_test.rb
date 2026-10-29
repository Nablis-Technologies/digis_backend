# frozen_string_literal: true

require "test_helper"

class CorePayoutAccountDigestTest < ActiveSupport::TestCase
  test "is deterministic for the same namespace and account number" do
    first = Core::PayoutAccountDigest.call(namespace: "seller-1", account_number: "1000000000")
    second = Core::PayoutAccountDigest.call(namespace: "seller-1", account_number: "1000000000")

    assert_equal first, second
    assert_match(/\A[0-9a-f]{64}\z/, first)
  end

  test "is scoped by namespace" do
    first = Core::PayoutAccountDigest.call(namespace: "seller-1", account_number: "1000000000")
    second = Core::PayoutAccountDigest.call(namespace: "seller-2", account_number: "1000000000")

    refute_equal first, second
  end
end
