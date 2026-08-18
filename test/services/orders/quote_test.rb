# frozen_string_literal: true

require "test_helper"

module Orders
  class QuoteTest < ActiveSupport::TestCase
    test "preserves exact immutable commercial results without recalculating them" do
      commercial_result = Commercial::Resolution::ChargeResult.new(
        currency: "ETB",
        quoted_at: Time.current,
        component_results: [],
        buyer_fee_total: 250,
        organizer_fee_total: 0,
        subsidy_total: 0
      )

      quote = Orders::Quote.new(
        commercial_results: [ commercial_result ],
        expires_at: 10.minutes.from_now
      )

      assert_same commercial_result, quote.commercial_results.first
      assert_predicate quote, :frozen?
      assert_predicate quote.commercial_results, :frozen?
      assert_raises(FrozenError) { quote.commercial_results << commercial_result }
    end
  end
end
