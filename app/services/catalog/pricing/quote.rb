# frozen_string_literal: true

module Catalog
  module Pricing
    # Produces a deterministic quote for a product in a requested charge
    # currency at a given time. A fixed override in the charge currency wins
    # outright; otherwise a base price is converted through the applicable
    # exchange rate with half-up rounding to the charge currency's minor units.
    class Quote < Core::BaseService
      CURRENCY_MINOR_UNITS = {
        JPY: 1, KRW: 1, VND: 1, CLP: 1,
        BHD: 1000, KWD: 1000, OMR: 1000, TND: 1000, JOD: 1000
      }.freeze

      def initialize(product:, charge_currency:, at: nil)
        @product = product
        @charge_currency = charge_currency.to_s.upcase
        @at = at || Time.current
      end

      def call
        override = @product.prices.overrides.active_at(@at).for_currency(@charge_currency).first
        if override
          return success(build_quote(source_type: "override", amount_minor: override.amount_minor,
                                      from_currency: @charge_currency, exchange_rate: nil))
        end

        base = @product.prices.base.active_at(@at).first
        return failure_i18n("catalog.pricing.errors.no_active_price") if base.blank?

        return success(build_quote(source_type: "base", amount_minor: base.amount_minor,
                                   from_currency: base.currency, exchange_rate: nil)) if base.currency == @charge_currency

        rate = Catalog::ExchangeRate.rate_for(from: base.currency, to: @charge_currency, at: @at)
        return failure_i18n("catalog.pricing.errors.unsupported_charge_currency") if rate.blank?

        converted = convert(base.amount_minor, base.currency, @charge_currency, rate.rate)
        success(build_quote(source_type: "exchange", amount_minor: converted,
                            from_currency: base.currency, exchange_rate: rate))
      end

      private

      def build_quote(source_type:, amount_minor:, from_currency:, exchange_rate:)
        Catalog::PriceQuote.new(
          product_id: @product.id,
          charge_currency: @charge_currency,
          amount_minor: amount_minor,
          source_type: source_type,
          from_currency: from_currency,
          exchange_rate_id: exchange_rate&.id,
          exchange_rate_value: exchange_rate&.rate,
          at: @at
        )
      end

      def convert(from_minor, from_currency, to_currency, rate)
        from_per = minor_unit(from_currency)
        to_per = minor_unit(to_currency)
        from_major = from_minor.to_d / from_per
        (from_major * rate * to_per).round(0, BigDecimal::ROUND_HALF_UP).to_i
      end

      def minor_unit(currency)
        CURRENCY_MINOR_UNITS.fetch(currency.to_sym, 100)
      end
    end
  end
end
