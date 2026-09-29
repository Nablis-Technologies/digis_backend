# frozen_string_literal: true

require "json"

module Orders
  # Binds guest payment-attempt and refresh requests to one order, buyer, and
  # canonical phone without exposing the phone or order's pricing evidence.
  class GuestOrderAccessToken < Core::BaseService
    PURPOSE = "orders.guest_order_access"

    def self.issue(order:, buyer:, phone:)
      new(order:, buyer:, phone:).issue
    end

    def self.decode(token:, order:, phone:)
      new(token:, order:, phone:).decode
    end

    def initialize(order: nil, buyer: nil, token: nil, phone:)
      @order = order
      @buyer = buyer
      @token = token
      @phone = phone
    end

    def issue
      normalized = normalized_phone!
      encryptor.encrypt_and_sign(
        JSON.generate(
          order_id: order.id.to_s,
          event_id: order.event_id.to_s,
          buyer_user_id: buyer.id.to_s,
          phone_digest: Core::PhoneIdentity::ResolveOrCreate.digest_for(normalized)
        ),
        purpose: PURPOSE
      )
    end

    def decode
      payload = JSON.parse(encryptor.decrypt_and_verify(token, purpose: PURPOSE)).deep_stringify_keys
      validate_binding!(payload)
      user = Core::User.find(payload.fetch("buyer_user_id"))
      return failure(invalid_error) unless user.id == order.buyer_user_id

      success(user)
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

    attr_reader :order, :buyer, :token, :phone

    def normalized_phone!
      normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(phone)
      raise ArgumentError if normalized.blank?

      normalized
    end

    def validate_binding!(payload)
      normalized = normalized_phone!
      valid = payload.fetch("order_id").to_s == order.id.to_s &&
        payload.fetch("event_id").to_s == order.event_id.to_s &&
        payload.fetch("buyer_user_id").to_s == order.buyer_user_id.to_s &&
        payload.fetch("phone_digest") == Core::PhoneIdentity::ResolveOrCreate.digest_for(normalized)
      raise ArgumentError unless valid
    end

    def invalid_error
      Core::BusinessError.new(
        I18n.t("orders.checkout.errors.invalid_guest_order_token"),
        code: "invalid_guest_order_token",
        status: :unprocessable_entity
      )
    end

    def encryptor
      secret = Rails.application.key_generator.generate_key(
        "orders.guest_order_access_token",
        ActiveSupport::MessageEncryptor.key_len
      )
      ActiveSupport::MessageEncryptor.new(secret)
    end
  end
end
