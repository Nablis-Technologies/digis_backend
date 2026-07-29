# frozen_string_literal: true

require "test_helper"

module Catalog
  module Pricing
    class QuoteTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "Festival Pass", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic",
            date_selection: "fixed", admissions_per_unit: 1
          },
          inventory_configuration: { mode: "unlimited" }
        ).value
      end

      test "uses an active fixed override before exchange conversion" do
        Catalog::ProductPrice.create!(
          event_product: @product, type: "override", currency: "USD",
          amount_minor: 2500, active_from: 1.day.ago
        )
        result = Catalog::Pricing::Quote.call(product: @product, charge_currency: "USD", at: Time.current)

        assert result.success?, result.error.inspect
        quote = result.value
        assert_equal "USD", quote.charge_currency
        assert_equal 2500, quote.amount_minor
        assert_equal "override", quote.source_type
        assert_nil quote.exchange_rate_id
      end

      test "converts a base price through the exchange rate" do
        Catalog::ProductPrice.create!(
          event_product: @product, type: "base", currency: "EUR",
          amount_minor: 1000, active_from: 1.day.ago
        )
        Catalog::ExchangeRate.create!(
          from_currency: "EUR", to_currency: "USD", rate: 1.1, effective_from: 2.days.ago
        )
        result = Catalog::Pricing::Quote.call(product: @product, charge_currency: "USD", at: Time.current)

        assert result.success?, result.error.inspect
        quote = result.value
        assert_equal "USD", quote.charge_currency
        assert_equal 1100, quote.amount_minor
        assert_equal "exchange", quote.source_type
        assert_not_nil quote.exchange_rate_id
        assert_equal "EUR", quote.from_currency
      end

      test "rounds half-up to the charge currency minor units" do
        Catalog::ProductPrice.create!(
          event_product: @product, type: "base", currency: "EUR",
          amount_minor: 1000, active_from: 1.day.ago
        )
        Catalog::ExchangeRate.create!(
          from_currency: "EUR", to_currency: "USD", rate: 1.1234, effective_from: 2.days.ago
        )
        quote = Catalog::Pricing::Quote.call(product: @product, charge_currency: "USD", at: Time.current).value
        assert_equal 1123, quote.amount_minor
      end

      test "honors currency-specific minor units (EUR -> JPY)" do
        Catalog::ProductPrice.create!(
          event_product: @product, type: "base", currency: "EUR",
          amount_minor: 1000, active_from: 1.day.ago
        )
        Catalog::ExchangeRate.create!(
          from_currency: "EUR", to_currency: "JPY", rate: 130.0, effective_from: 2.days.ago
        )
        quote = Catalog::Pricing::Quote.call(product: @product, charge_currency: "JPY", at: Time.current).value
        assert_equal 1300, quote.amount_minor
      end

      test "fails when charge currency has no override and no exchange rate" do
        Catalog::ProductPrice.create!(
          event_product: @product, type: "base", currency: "EUR",
          amount_minor: 1000, active_from: 1.day.ago
        )
        result = Catalog::Pricing::Quote.call(product: @product, charge_currency: "JPY", at: Time.current)
        assert result.failure?
      end

      test "zero price is allowed and quoted" do
        Catalog::ProductPrice.create!(
          event_product: @product, type: "override", currency: "USD",
          amount_minor: 0, active_from: 1.day.ago
        )
        quote = Catalog::Pricing::Quote.call(product: @product, charge_currency: "USD", at: Time.current).value
        assert_equal 0, quote.amount_minor
      end

      test "quote evidence is immutable" do
        Catalog::ProductPrice.create!(
          event_product: @product, type: "override", currency: "USD",
          amount_minor: 2500, active_from: 1.day.ago
        )
        quote = Catalog::Pricing::Quote.call(product: @product, charge_currency: "USD", at: Time.current).value
        assert_raises(NoMethodError) { quote.amount_minor = 1 }
      end
    end
  end
end
