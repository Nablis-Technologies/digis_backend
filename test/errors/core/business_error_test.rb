# frozen_string_literal: true

require "test_helper"

class Core::BusinessErrorTest < ActiveSupport::TestCase
  test "exposes stable API failure fields" do
    error = Core::BusinessError.new(
      "Inventory is no longer available",
      code: "inventory_unavailable",
      status: :conflict,
      errors: { quantity: ["exceeds availability"] },
      meta: { retryable: false }
    )

    assert_equal "inventory_unavailable", error.code
    assert_equal :conflict, error.status
    assert_equal({ quantity: ["exceeds availability"] }, error.errors)
    assert_equal({ retryable: false }, error.meta)
  end
end
