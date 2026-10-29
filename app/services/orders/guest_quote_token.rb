# frozen_string_literal: true

require "json"

module Orders
  # Adds a phone-identity binding around the normal encrypted quote token. A
  # guest token is opaque to the browser and cannot be replayed for a different
  # event, buyer, or canonical phone identity.
  class GuestQuoteToken < Core::BaseService
    PURPOSE = "orders.guest_checkout_quote"
    INVALID_CODE = "invalid_guest_quote"
    Result = Data.define(:quote, :buyer)

    def self.issue(quote:, event:, buyer:, phone:)
      new(quote:, event:, buyer:, phone:).issue
    end

    def self.decode(token:, event:, phone:)
      new(token:, event:, phone:).decode
    end

    def initialize(quote: nil, token: nil, event:, buyer: nil, phone:)
      @quote = quote
      @token = token
      @event = event
      @buyer = buyer
      @phone = phone
    end

    def issue
      normalized = normalized_phone!
      payload = {
        event_id: event.id.to_s,
        buyer_user_id: buyer.id.to_s,
        phone_digest: Core::PhoneIdentity::ResolveOrCreate.digest_for(normalized),
        quote_token: Orders::QuoteToken.issue(quote:, event:, buyer:)
      }
      encryptor.encrypt_and_sign(JSON.generate(payload), purpose: PURPOSE)
    end

    def decode
      payload = JSON.parse(encryptor.decrypt_and_verify(token, purpose: PURPOSE)).deep_stringify_keys
      validate_binding!(payload)
      buyer = Core::User.find(payload.fetch("buyer_user_id"))
      result = Orders::QuoteToken.decode(token: payload.fetch("quote_token"), event:, buyer:)
      return failure(invalid_error) if result.failure?

      success(Result.new(quote: result.value, buyer:))
    rescue ActiveSupport::MessageEncryptor::InvalidMessage,
           ActiveSupport::MessageVerifier::InvalidSignature,
           JSON::ParserError,
           ActiveRecord::RecordNotFound,
           KeyError,
           ArgumentError,
           TypeError
      failure(invalid_error)
    end

    private

    attr_reader :quote, :token, :event, :buyer, :phone

    def normalized_phone!
      normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(phone)
      raise ArgumentError if normalized.blank?

      normalized
    end

    def validate_binding!(payload)
      normalized = normalized_phone!
      valid = payload.fetch("event_id").to_s == event.id.to_s &&
        payload.fetch("phone_digest") == Core::PhoneIdentity::ResolveOrCreate.digest_for(normalized)
      raise ArgumentError unless valid
    end

    def invalid_error
      Core::BusinessError.new(
        I18n.t("orders.checkout.errors.invalid_guest_quote"),
        code: INVALID_CODE,
        status: :unprocessable_entity
      )
    end

    def encryptor
      secret = Rails.application.key_generator.generate_key(
        "orders.guest_quote_token",
        ActiveSupport::MessageEncryptor.key_len
      )
      ActiveSupport::MessageEncryptor.new(secret)
    end
  end
end
