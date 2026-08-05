# frozen_string_literal: true

require "test_helper"

module Catalog
  module Pricing
    class CurrencyConverterTest < ActiveSupport::TestCase
      test "converts using a database rate with currency-specific minor units" do
        rate = Catalog::ExchangeRate.create!(
          from_currency: "EUR", to_currency: "JPY", rate: 130.0,
          effective_from: 2.days.ago
        )

        result = CurrencyConverter.call(
          amount_minor: 1_000,
          from_currency: "EUR",
          to_currency: "JPY",
          at: Time.current
        )

        assert result.success?, result.error&.message
        assert_equal 1_300, result.value.amount_minor
        assert_equal rate.id, result.value.exchange_rate_id
      end

      test "validates supplied FX evidence against the stored rate" do
        rate = Catalog::ExchangeRate.create!(
          from_currency: "ETB", to_currency: "USD", rate: 0.018,
          effective_from: 2.days.ago
        )

        evidence = Catalog::PriceQuote.new(
          product_id: SecureRandom.uuid,
          charge_currency: "USD",
          amount_minor: 1,
          source_type: "exchange",
          from_currency: "ETB",
          exchange_rate_id: rate.id,
          exchange_rate_value: rate.rate,
          at: Time.current
        )

        result = CurrencyConverter.call(
          amount_minor: 10_000,
          from_currency: "ETB",
          to_currency: "USD",
          at: Time.current,
          fx_quote: evidence
        )

        assert result.success?, result.error&.message
        assert_equal 180, result.value.amount_minor
      end

      test "rejects mismatched or tampered FX evidence" do
        result = CurrencyConverter.call(
          amount_minor: 10_000,
          from_currency: "ETB",
          to_currency: "USD",
          at: Time.current,
          fx_quote: { exchange_rate_id: SecureRandom.uuid, exchange_rate_value: 99 }
        )

        assert result.failure?
        assert_equal I18n.t("catalog.promotion_quote.errors.invalid_fx_quote"), result.error.message
      end
    end
  end
end
