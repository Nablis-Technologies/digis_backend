# frozen_string_literal: true

require "digest"
require "json"

module Orders
  # Immutable quote envelope for server-resolved product, FX, promotion, and
  # Commercial evidence. Orders carries the exact result forward; it never
  # recalculates or mutates a fee after the quote has been built.
  class Quote
    ATTRIBUTES = %i[
      items commercial_results promotion_quote charge_currency settlement_currency sales_channel provider
      payment_method quoted_at expires_at
      subtotal_minor discount_minor buyer_fee_total organizer_fee_total subsidy_total total_minor
      settlement_total_minor exchange_rate exchange_rate_source exchange_rate_quoted_at
      exchange_rate_expires_at signature
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(
      commercial_results:, expires_at:, items: [], promotion_quote: nil,
      charge_currency: nil, settlement_currency: nil, sales_channel: "online", provider: nil,
      payment_method: nil, quoted_at: nil,
      subtotal_minor: nil, discount_minor: 0, buyer_fee_total: 0,
      organizer_fee_total: 0, subsidy_total: 0, total_minor: nil,
      settlement_total_minor: nil, exchange_rate: nil, exchange_rate_source: nil,
      exchange_rate_quoted_at: nil, exchange_rate_expires_at: nil, signature: nil
    )
      @items = deep_freeze(items.to_a.dup)
      @commercial_results = deep_freeze(commercial_results.to_a.dup)
      @promotion_quote = deep_freeze(promotion_quote)
      @charge_currency = charge_currency&.to_s&.upcase&.freeze
      @settlement_currency = settlement_currency&.to_s&.upcase&.freeze
      @sales_channel = sales_channel.to_s.downcase.freeze
      @provider = provider&.to_s&.downcase&.freeze
      @payment_method = payment_method&.to_s&.downcase&.freeze
      @quoted_at = freeze_time(quoted_at || Time.current)
      @expires_at = freeze_time(expires_at)
      @subtotal_minor = subtotal_minor
      @discount_minor = discount_minor
      @buyer_fee_total = buyer_fee_total
      @organizer_fee_total = organizer_fee_total
      @subsidy_total = subsidy_total
      @total_minor = total_minor
      @settlement_total_minor = settlement_total_minor
      @exchange_rate = exchange_rate
      @exchange_rate_source = exchange_rate_source&.to_s&.freeze
      @exchange_rate_quoted_at = freeze_time(exchange_rate_quoted_at)
      @exchange_rate_expires_at = freeze_time(exchange_rate_expires_at)
      @signature = (signature || build_signature).to_s.freeze
      freeze
    end

    def commercial_result
      commercial_results.first
    end

    def to_h
      {
        items: items.map { |item| item.respond_to?(:to_h) ? item.to_h : item },
        commercial_results: commercial_results.map(&:to_h),
        promotion_quote: promotion_quote&.to_h,
        charge_currency:, settlement_currency:, sales_channel:, provider:, payment_method:,
        quoted_at: quoted_at&.iso8601(6), expires_at: expires_at.iso8601(6),
        subtotal_minor:, discount_minor:, buyer_fee_total:, organizer_fee_total:, subsidy_total:, total_minor:,
        settlement_total_minor:, exchange_rate:, exchange_rate_source:,
        exchange_rate_quoted_at: exchange_rate_quoted_at&.iso8601(6),
        exchange_rate_expires_at: exchange_rate_expires_at&.iso8601(6), signature:
      }
    end

    private

    def build_signature
      Digest::SHA256.hexdigest(JSON.generate(canonical(to_h_without_signature)))
    end

    def to_h_without_signature
      {
        items: items.map { |item| item.respond_to?(:to_h) ? item.to_h : item },
        commercial_results: commercial_results.map(&:to_h),
        promotion_quote: promotion_quote&.to_h,
        charge_currency:, settlement_currency:, sales_channel:, provider:, payment_method:,
        quoted_at: quoted_at&.iso8601(6), expires_at: expires_at.iso8601(6),
        subtotal_minor:, discount_minor:, buyer_fee_total:, organizer_fee_total:, subsidy_total:, total_minor:,
        settlement_total_minor:, exchange_rate:, exchange_rate_source:,
        exchange_rate_quoted_at: exchange_rate_quoted_at&.iso8601(6),
        exchange_rate_expires_at: exchange_rate_expires_at&.iso8601(6)
      }
    end

    def canonical(value)
      case value
      when Hash
        value.stringify_keys.sort.to_h { |key, child| [ key, canonical(child) ] }
      when Array
        value.map { |child| canonical(child) }
      else
        value
      end
    end

    def freeze_time(value)
      return if value.nil?

      value.to_time.utc.freeze
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| deep_freeze(key); deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      else
        value.to_h.each_value { |child| deep_freeze(child) } if value.respond_to?(:to_h) && !value.is_a?(Time)
      end
      value.freeze
    end
  end
end
