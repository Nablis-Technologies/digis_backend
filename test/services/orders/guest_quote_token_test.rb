# frozen_string_literal: true

require "test_helper"

module Orders
  class GuestQuoteTokenTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = Core::User.create!(phone: "+251911000031")
      @quote = Orders::Quote.new(
        commercial_results: [],
        expires_at: 10.minutes.from_now,
        charge_currency: "ETB",
        settlement_currency: "ETB",
        subtotal_minor: 0,
        total_minor: 0,
        settlement_total_minor: 0,
        exchange_rate: 1,
        exchange_rate_source: "same_currency"
      )
    end

    test "round trips a quote only for the bound canonical phone identity" do
      token = GuestQuoteToken.issue(quote: @quote, event: @event, buyer: @buyer, phone: "0911000031")

      result = GuestQuoteToken.decode(token:, event: @event, phone: "+251 911 000 031")

      assert_predicate result, :success?
      assert_equal @buyer.id, result.value.buyer.id
      assert_equal @quote.signature, result.value.quote.signature
    end

    test "rejects a quote token presented with a different phone identity" do
      token = GuestQuoteToken.issue(quote: @quote, event: @event, buyer: @buyer, phone: "0911000031")

      result = GuestQuoteToken.decode(token:, event: @event, phone: "0911000032")

      assert_predicate result, :failure?
      assert_equal "invalid_guest_quote", result.error.code
    end
  end
end
