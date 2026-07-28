# frozen_string_literal: true

module Catalog
  # One applicable exchange rate between two ISO-4217 currencies. Historical
  # rates are retained via an effective window; the latest applicable rate at a
  # given time wins.
  class ExchangeRate < Catalog::ApplicationRecord
    self.table_name = "catalog_exchange_rates"

    validates :from_currency,
              presence: true,
              format: { with: /\A[A-Z]{3}\z/, allow_blank: true,
                        message: ->(*_args) { I18n.t("catalog.exchange_rate.errors.currency_format") } }
    validates :to_currency,
              presence: true,
              format: { with: /\A[A-Z]{3}\z/, allow_blank: true,
                        message: ->(*_args) { I18n.t("catalog.exchange_rate.errors.currency_format") } }
    validates :rate, presence: true, numericality: { greater_than: 0 }
    validates :effective_from, presence: true

    scope :applicable, lambda { |at|
      where(active: true)
        .where("effective_from <= ?", at)
        .where("(effective_to IS NULL OR effective_to > ?)", at)
    }

    def self.rate_for(from:, to:, at:)
      applicable(at)
        .where(from_currency: from.to_s.upcase, to_currency: to.to_s.upcase)
        .order(effective_from: :desc)
        .first
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id from_currency to_currency rate effective_from effective_to active created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end
  end
end
