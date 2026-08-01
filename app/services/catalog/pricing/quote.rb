# frozen_string_literal: true

module Catalog
  module Pricing
    # Produces a deterministic quote for a product in a requested charge
    # currency at a given time. A fixed override in the charge currency wins
    # outright; otherwise a base price is converted through the applicable
    # exchange rate with half-up rounding to the charge currency's minor units.
    class Quote < Core::BaseService
      def initialize(product:, charge_currency:, at: nil)
        @product = product
        @charge_currency = charge_currency.to_s.upcase
        @at = at || Time.current
      end

      def call
        override = @product.prices.overrides.active_at(@at).for_currency(@charge_currency).first
        if override
          return success(build_quote(source_type: "override", amount_minor: override.amount_minor,
                                      from_currency: @charge_currency,
                                      exchange_rate_id: nil, exchange_rate_value: nil))
        end

        base = @product.prices.base.active_at(@at).first
        return failure_i18n("catalog.pricing.errors.no_active_price") if base.blank?

        conversion = CurrencyConverter.call(
          amount_minor: base.amount_minor,
          from_currency: base.currency,
          to_currency: @charge_currency,
          at: @at
        )
        return failure_i18n("catalog.pricing.errors.unsupported_charge_currency") if conversion.failure?

        converted = conversion.value
        success(build_quote(
          source_type: converted.exchange_rate_id ? "exchange" : "base",
          amount_minor: converted.amount_minor,
          from_currency: converted.from_currency,
          exchange_rate_id: converted.exchange_rate_id,
          exchange_rate_value: converted.exchange_rate_value
        ))
      end

      private

      def build_quote(source_type:, amount_minor:, from_currency:, exchange_rate_id:, exchange_rate_value:)
        Catalog::PriceQuote.new(
          product_id: @product.id,
          charge_currency: @charge_currency,
          amount_minor: amount_minor,
          source_type: source_type,
          from_currency: from_currency,
          exchange_rate_id: exchange_rate_id,
          exchange_rate_value: exchange_rate_value,
          at: @at
        )
      end
    end
  end
end
