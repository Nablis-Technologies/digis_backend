# frozen_string_literal: true

module Catalog
  # Refreshes exchange rates from an external source. The rate map is injected
  # (e.g. by a provider adapter or scheduler) so the job stays free of gateway
  # policy; each entry is recorded as the latest applicable rate.
  class RefreshExchangeRatesJob < ApplicationJob
    queue_as :default

    def perform(base_currency:, rates:)
      base = base_currency.to_s.upcase

      rates.each do |currency, rate|
        Catalog::ExchangeRates::Record.new(
          from_currency: base,
          to_currency: currency.to_s.upcase,
          rate: rate
        ).call
      end
    end
  end
end
