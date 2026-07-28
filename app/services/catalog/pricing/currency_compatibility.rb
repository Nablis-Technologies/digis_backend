# frozen_string_literal: true

module Catalog
  module Pricing
    # Answers whether a product can be quoted in a charge currency at a given
    # time: either a fixed override exists in that currency, or a base price
    # exists with a direct currency match or an applicable exchange rate.
    class CurrencyCompatibility < Core::BaseService
      def initialize(product:, charge_currency:, at: nil)
        @product = product
        @charge_currency = charge_currency.to_s.upcase
        @at = at || Time.current
      end

      def call
        return success(supported: true) if override_exists?
        return success(supported: true) if exchange_path_exists?

        failure_i18n("catalog.pricing.errors.unsupported_charge_currency")
      end

      private

      def override_exists?
        @product.prices.overrides.active_at(@at).for_currency(@charge_currency).exists?
      end

      def exchange_path_exists?
        base = @product.prices.base.active_at(@at).first
        return false if base.blank?
        return true if base.currency == @charge_currency

        Catalog::ExchangeRate.rate_for(from: base.currency, to: @charge_currency, at: @at).present?
      end
    end
  end
end
