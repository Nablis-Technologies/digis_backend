# frozen_string_literal: true

require "test_helper"

class Core::IdempotencyKeyTest < ActiveSupport::TestCase
  test "normalizes a caller key without exposing it in derived storage keys" do
    key = Core::IdempotencyKey.new(" checkout-123 ")

    assert_equal "checkout-123", key.to_s
    assert_match(/\A[0-9a-f]{64}\z/, key.digest)
  end

  test "rejects blank and oversized keys" do
    assert_raises(ArgumentError) { Core::IdempotencyKey.new(" ") }
    assert_raises(ArgumentError) { Core::IdempotencyKey.new("x" * 256) }
  end
end
