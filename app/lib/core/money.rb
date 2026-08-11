# frozen_string_literal: true

module Core
  class Money
    CurrencyMismatch = Class.new(Core::Error)

    attr_reader :amount_minor, :currency

    def initialize(amount_minor:, currency:)
      normalized_currency = currency.to_s.upcase
      raise ArgumentError, I18n.t("core.errors.amount_minor_integer") unless amount_minor.is_a?(Integer)
      raise ArgumentError, I18n.t("core.errors.currency_format") unless normalized_currency.match?(/\A[A-Z]{3}\z/)

      @amount_minor = amount_minor
      @currency = normalized_currency
      freeze
    end

    def +(other)
      assert_same_currency!(other)
      self.class.new(amount_minor: amount_minor + other.amount_minor, currency:)
    end

    def -(other)
      assert_same_currency!(other)
      self.class.new(amount_minor: amount_minor - other.amount_minor, currency:)
    end

    private

    def assert_same_currency!(other)
      return if other.is_a?(self.class) && other.currency == currency

      other_currency = other.respond_to?(:currency) ? other.currency : other.class.name
      raise CurrencyMismatch, I18n.t("core.errors.currency_mismatch", currency:, other_currency:)
    end
  end
end
