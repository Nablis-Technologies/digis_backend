# frozen_string_literal: true

require "test_helper"

class Core::MoneyTest < ActiveSupport::TestCase
  test "adds only matching currencies" do
    total = Core::Money.new(amount_minor: 125, currency: "etb") +
      Core::Money.new(amount_minor: 75, currency: "ETB")

    assert_equal 200, total.amount_minor
    assert_equal "ETB", total.currency
  end

  test "rejects cross-currency arithmetic" do
    error = assert_raises(Core::Money::CurrencyMismatch) do
      Core::Money.new(amount_minor: 100, currency: "ETB") +
        Core::Money.new(amount_minor: 100, currency: "USD")
    end

    assert_equal "ETB cannot be combined with USD", error.message
  end
end
