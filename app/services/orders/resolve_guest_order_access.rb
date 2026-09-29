# frozen_string_literal: true

module Orders
  # Resolves an existing guest quote token or an admission-selection order
  # token to the one shadow buyer allowed to act on the order.
  class ResolveGuestOrderAccess < Core::BaseService
    def initialize(order:, phone:, order_access_token: nil, quote_token: nil)
      @order = order
      @phone = phone
      @order_access_token = order_access_token
      @quote_token = quote_token
    end

    def call
      return GuestOrderAccessToken.decode(
        token: @order_access_token, order:, phone: @phone
      ) if @order_access_token.present?
      return failure(invalid_access) if @quote_token.blank?

      decoded = GuestQuoteToken.decode(token: @quote_token, event: order.event, phone: @phone)
      return decoded if decoded.failure?
      return failure(order_not_owned) unless decoded.value.buyer.id == order.buyer_user_id

      success(decoded.value.buyer)
    end

    private

    attr_reader :order

    def invalid_access
      Core::BusinessError.new(
        I18n.t("orders.checkout.errors.invalid_guest_order_token"),
        code: "invalid_guest_order_token",
        status: :unprocessable_entity
      )
    end

    def order_not_owned
      Core::BusinessError.new(
        I18n.t("orders.payments.errors.payment_order_not_owned"),
        code: "payment_order_not_owned",
        status: :forbidden
      )
    end
  end
end
