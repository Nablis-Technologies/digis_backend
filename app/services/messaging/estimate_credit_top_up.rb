# frozen_string_literal: true

require "digest"

module Messaging
  # Quotes a channel-specific credit quantity without mutating account state.
  class EstimateCreditTopUp < Core::BaseService
    def initialize(organization:, channel:, quantity:, currency:, country_code: nil, at: Time.current)
      @organization = organization
      @channel = channel.to_s.strip.downcase
      @quantity = quantity
      @currency = currency.to_s.strip.upcase
      @country_code = country_code.to_s.strip.upcase.presence
      @at = at.to_time
    end

    def call
      return failure(error(:invalid_credit_quantity, :unprocessable_entity)) unless valid_quantity?

      rate_result = ResolveCreditRate.call(
        organization:, channel:, quantity:, currency:, country_code:, at:
      )
      return failure(rate_result.error) if rate_result.failure?

      selected = rate_result.value
      success(
        quantity:,
        channel:,
        currency:,
        country_code:,
        unit_price_minor: selected.fetch(:unit_price_minor),
        amount_minor: selected.fetch(:unit_price_minor) * quantity,
        rate_version: selected.fetch(:rate_version),
        rate_scope: selected.fetch(:scope),
        tier: selected[:tier],
        price_digest: price_digest(selected)
      )
    end

    private

    attr_reader :organization, :channel, :quantity, :currency, :country_code, :at

    def valid_quantity?
      quantity.is_a?(Integer) && quantity.positive?
    end

    def price_digest(selected)
      Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(
        channel:, currency:, country_code:, quantity:,
        rate_version_id: selected.fetch(:rate_version).id,
        unit_price_minor: selected.fetch(:unit_price_minor), tier: selected[:tier]
      ))
    end

    def error(key, status)
      Core::BusinessError.new(I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
    end
  end
end
