# frozen_string_literal: true

module Catalog
  module ExchangeRates
    # Records a single exchange rate (latest applicable at its effective time).
    class Record < Core::BaseService
      def initialize(from_currency:, to_currency:, rate:, effective_from: nil, effective_to: nil)
        @from_currency = from_currency.to_s.upcase
        @to_currency = to_currency.to_s.upcase
        @rate = rate
        @effective_from = effective_from
        @effective_to = effective_to
      end

      def call
        rate = Catalog::ExchangeRate.new(
          from_currency: @from_currency,
          to_currency: @to_currency,
          rate: @rate,
          effective_from: @effective_from || Time.current,
          effective_to: @effective_to
        )

        return failure(Core::Error.new(rate.errors.full_messages.join(", "))) unless rate.save

        success(rate)
      end
    end
  end
end
