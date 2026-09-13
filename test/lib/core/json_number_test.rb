# frozen_string_literal: true

require "json"
require "test_helper"

class Core::JsonNumberTest < ActiveSupport::TestCase
  test "keeps exact JSON wire values safe for Rails serialization" do
    number = Core::JsonNumber.new("5.25")

    assert_equal "5.25", number.as_json
    assert_equal({ "amount" => "5.25" }, { amount: number }.as_json)
    assert_equal '{"amount":5.25}', JSON.generate(amount: number)
  end

  test "removes a redundant fractional zero from whole numbers" do
    number = Core::JsonNumber.new("500.0")

    assert_equal "500", number.to_s
    assert_equal '{"amount":500}', JSON.generate(amount: number)
  end

  test "rejects values that are not JSON decimal numbers" do
    assert_raises(ArgumentError) { Core::JsonNumber.new("not-a-number") }
  end
end
