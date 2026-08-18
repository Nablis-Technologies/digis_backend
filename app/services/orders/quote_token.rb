# frozen_string_literal: true

require "json"

module Orders
  # Carries the server-resolved quote between the preview and checkout
  # requests. The payload is encrypted rather than merely signed because it
  # contains Commercial evidence that is needed for immutable order snapshots
  # but must never become buyer-visible implementation detail.
  class QuoteToken < Core::BaseService
    PURPOSE = "orders.checkout_quote"
    INVALID_QUOTE_CODE = "invalid_quote"

    class InvalidToken < StandardError; end

    def self.issue(quote:, event:, buyer:)
      new(quote:, event:, buyer:).issue
    end

    def self.decode(token:, event:, buyer:)
      new(token:, event:, buyer:).decode
    end

    def initialize(quote: nil, token: nil, event:, buyer:)
      @quote = quote
      @token = token
      @event = event
      @buyer = buyer
    end

    def issue
      encryptor.encrypt_and_sign(JSON.generate(payload), purpose: PURPOSE)
    end

    def decode
      success(hydrate(JSON.parse(encryptor.decrypt_and_verify(token, purpose: PURPOSE))))
    rescue ActiveSupport::MessageEncryptor::InvalidMessage,
           ActiveSupport::MessageVerifier::InvalidSignature,
           JSON::ParserError,
           KeyError,
           NoMethodError,
           TypeError,
           ArgumentError,
           InvalidToken
      failure(
        Core::BusinessError.new(
          I18n.t("orders.checkout.errors.invalid_quote"),
          code: INVALID_QUOTE_CODE,
          status: :unprocessable_entity
        )
      )
    end

    private

    attr_reader :quote, :token, :event, :buyer

    def payload
      {
        event_id: event.id.to_s,
        buyer_user_id: buyer.id.to_s,
        quote: plain_value(quote.to_h)
      }
    end

    def hydrate(raw_payload)
      payload = raw_payload.deep_symbolize_keys
      validate_binding!(payload)
      quote_attributes = payload.fetch(:quote)
      Orders::Quote.new(
        **quote_attributes.except(:items, :commercial_results, :promotion_quote),
        items: quote_attributes.fetch(:items).map { |item| hydrate_item(item) },
        commercial_results: quote_attributes.fetch(:commercial_results).map { |result| hydrate_charge_result(result) },
        promotion_quote: hydrate_promotion_quote(quote_attributes[:promotion_quote])
      )
    end

    def validate_binding!(payload)
      return if payload.fetch(:event_id).to_s == event.id.to_s &&
        payload.fetch(:buyer_user_id).to_s == buyer.id.to_s

      raise InvalidToken
    end

    def hydrate_item(raw_item)
      item = raw_item.deep_symbolize_keys
      Orders::QuoteItem.new(
        **item.except(:price_quote, :commercial_result),
        price_quote: Catalog::PriceQuote.new(**item.fetch(:price_quote)),
        commercial_result: hydrate_charge_result(item.fetch(:commercial_result))
      )
    end

    def hydrate_charge_result(raw_result)
      result = raw_result.deep_symbolize_keys
      components = result.fetch(:component_results).map do |raw_component|
        component = raw_component.deep_symbolize_keys
        component[:explanation] = component[:explanation]&.deep_symbolize_keys
        Commercial::Resolution::ComponentResult.new(component)
      end

      Commercial::Resolution::ChargeResult.new(
        currency: result.fetch(:currency),
        settlement_currency: result.fetch(:settlement_currency),
        quoted_at: result.fetch(:quoted_at).to_time,
        definition_signature: result[:definition_signature],
        component_results: components,
        buyer_fee_total: result.fetch(:buyer_fee_total),
        organizer_fee_total: result.fetch(:organizer_fee_total),
        subsidy_total: result.fetch(:subsidy_total)
      )
    end

    def hydrate_promotion_quote(raw_quote)
      return unless raw_quote

      quote = raw_quote.deep_symbolize_keys
      quote[:at] = quote[:at].to_time if quote[:at].present?
      Catalog::PromotionQuote.new(**quote)
    end

    def encryptor
      secret = Rails.application.key_generator.generate_key(
        "orders.quote_token",
        ActiveSupport::MessageEncryptor.key_len
      )
      ActiveSupport::MessageEncryptor.new(secret)
    end

    def plain_value(value)
      case value
      when NilClass
        nil
      when Time, ActiveSupport::TimeWithZone
        value.iso8601(6)
      when BigDecimal
        value.to_s("F")
      when Hash
        value.to_h { |key, child| [ key.to_s, plain_value(child) ] }
      when Array
        value.map { |child| plain_value(child) }
      else
        value.respond_to?(:to_h) ? plain_value(value.to_h) : value
      end
    end
  end
end
