# frozen_string_literal: true

module Catalog
  module Pricing
    class CurrencyConverter < Core::BaseService
      CURRENCY_MINOR_UNITS = {
        JPY: 1, KRW: 1, VND: 1, CLP: 1,
        BHD: 1000, KWD: 1000, OMR: 1000, TND: 1000, JOD: 1000
      }.freeze

      Conversion = Data.define(
        :amount_minor, :from_currency, :to_currency,
        :exchange_rate_id, :exchange_rate_value
      )

      def initialize(amount_minor:, from_currency:, to_currency:, at:, fx_quote: nil)
        @amount_minor = amount_minor
        @from_currency = from_currency.to_s.upcase
        @to_currency = to_currency.to_s.upcase
        @at = at
        @fx_quote = fx_quote
      end

      def call
        return success(build_conversion) if @from_currency == @to_currency

        rate = @fx_quote.nil? ? database_rate : evidenced_rate
        return failure_i18n(error_key) if rate.blank?

        success(build_conversion(rate))
      end

      private

      def database_rate
        Catalog::ExchangeRate.rate_for(from: @from_currency, to: @to_currency, at: @at)
      end

      def evidenced_rate
        rate_id = evidence_value(:exchange_rate_id)
        rate_value = evidence_value(:exchange_rate_value)
        from_currency = evidence_value(:from_currency)
        to_currency = evidence_value(:to_currency, :charge_currency)
        return if [ rate_id, rate_value, from_currency, to_currency ].any?(&:blank?)
        return unless from_currency.to_s.upcase == @from_currency
        return unless to_currency.to_s.upcase == @to_currency

        rate = Catalog::ExchangeRate.find_by(id: rate_id)
        return if rate.blank?
        return unless rate.from_currency == @from_currency && rate.to_currency == @to_currency
        return unless exact_rate?(rate.rate, rate_value)

        rate
      end

      def evidence_value(*keys)
        keys.each do |key|
          return @fx_quote.public_send(key) if @fx_quote.respond_to?(key)
          return @fx_quote[key] if @fx_quote.is_a?(Hash) && @fx_quote.key?(key)
          return @fx_quote[key.to_s] if @fx_quote.is_a?(Hash) && @fx_quote.key?(key.to_s)
        end

        nil
      end

      def exact_rate?(stored_rate, supplied_rate)
        BigDecimal(stored_rate.to_s) == BigDecimal(supplied_rate.to_s)
      rescue ArgumentError, TypeError
        false
      end

      def build_conversion(rate = nil)
        Conversion.new(
          amount_minor: rate ? converted_amount(rate.rate) : @amount_minor,
          from_currency: @from_currency,
          to_currency: @to_currency,
          exchange_rate_id: rate&.id,
          exchange_rate_value: rate&.rate
        )
      end

      def converted_amount(rate)
        from_per = minor_unit(@from_currency)
        to_per = minor_unit(@to_currency)
        from_major = @amount_minor.to_d / from_per
        (from_major * rate * to_per).round(0, BigDecimal::ROUND_HALF_UP).to_i
      end

      def minor_unit(currency)
        CURRENCY_MINOR_UNITS.fetch(currency.to_sym, 100)
      end

      def error_key
        @fx_quote.nil? ? "catalog.promotion_quote.errors.unsupported_currency" :
          "catalog.promotion_quote.errors.invalid_fx_quote"
      end
    end
  end
end
