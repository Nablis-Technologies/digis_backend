# frozen_string_literal: true

module Orders
  # Projects buyer-safe recovery details only from server-authenticated or
  # OTP-verified admission context; guest access remains order and phone bound.
  class ActiveCheckoutRecovery
    def self.call(order:, context:)
      new(order:, context:).call
    end

    def initialize(order:, context:)
      @order = order
      @context = context
    end

    def call
      return unless authorized_context?

      recovery = { order_id: order.id, expires_at: order.expires_at }
      recovery[:payment] = payment_summary if payment
      recovery[:order_access_token] = guest_order_token if verified_guest?
      recovery
    end

    private

    attr_reader :order, :context

    def authorized_context?
      return false unless context.is_a?(Orders::AdmissionSelectionContext)
      return false unless context.buyer&.id.to_s == order.buyer_user_id.to_s
      return context.guest_otp_verified == true && context.phone.present? if context.guest

      context.actor&.id.to_s == context.buyer.id.to_s
    end

    def payment
      @payment ||= order.payments.current.order(attempt_number: :desc).first
    end

    def payment_summary
      { id: payment.id, status: payment.status, checkout_url: payment.checkout_url }
    end

    def verified_guest?
      context.guest && context.guest_otp_verified == true
    end

    def guest_order_token
      Orders::GuestOrderAccessToken.issue(order:, buyer: context.buyer, phone: context.phone)
    end
  end
end
