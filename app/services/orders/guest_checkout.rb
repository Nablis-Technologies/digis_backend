# frozen_string_literal: true

module Orders
  # Reuses the authenticated checkout command after a guest quote has verified
  # the shadow buyer binding. No guest-specific order or inventory path exists.
  class GuestCheckout < Core::BaseService
    def initialize(quote:, event:, buyer:, idempotency_key:)
      @quote = quote
      @event = event
      @buyer = buyer
      @idempotency_key = idempotency_key
    end

    def call
      return failure(guest_error(:guest_buyer_required, :unprocessable_entity)) unless shadow_user?

      result = Orders::CreateCheckout.call(
        quote:,
        event:,
        buyer:,
        idempotency_key:
      )
      Core::Telemetry.instrument(
        "orders.guest_checkout.order",
        aggregate_id: buyer.id,
        event_id: event.id,
        outcome: result.success? ? "created" : "failed",
        code: result.error&.code
      ) { }
      result
    end

    private

    attr_reader :quote, :event, :buyer, :idempotency_key

    def shadow_user?
      buyer.is_a?(Core::User) && buyer.verified_at.blank? && buyer.password_digest.blank?
    end

    def guest_error(key, status)
      Core::BusinessError.new(
        I18n.t("orders.checkout.errors.#{key}"), code: key.to_s, status:
      )
    end
  end
end
