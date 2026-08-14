# frozen_string_literal: true

module Events
  module CancellationTestHelpers
    private

    def create_cancellation_order(accepted: true, amount_minor: 1_000, fulfillment_status: "pending")
      product = Catalog::EventProduct.create!(
        event: @event,
        name: "Cancellation product #{SecureRandom.hex(4)}",
        type: "merchandise",
        status: "active",
        inventory_mode: "unlimited"
      )
      order = Orders::Order.create!(
        event: @event,
        buyer_user: core_users(:attendee),
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: amount_minor,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: amount_minor,
        settlement_currency: "ETB",
        settlement_total_minor: amount_minor,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      item = Orders::OrderItem.create!(
        order:,
        event_product: product,
        name_snapshot: product.name,
        type_snapshot: "merchandise",
        quantity: 1,
        base_currency: "ETB",
        base_unit_amount_minor: amount_minor,
        charge_currency: "ETB",
        charge_unit_amount_minor: amount_minor,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: amount_minor,
        fulfillment_status:
      )
      order.update!(status: "fulfilled", paid_at: Time.current)
      payment = Orders::Payment.create!(
        order:,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "succeeded",
        amount_minor: amount_minor,
        currency: "ETB",
        commercial_signature: order.commercial_signature,
        buyer_fee_minor: 0,
        organizer_fee_minor: 0,
        idempotency_key: "cancellation-payment-#{SecureRandom.hex(6)}",
        provider_reference: "cancellation-provider-#{SecureRandom.hex(4)}",
        accepted_at: accepted ? Time.current : nil,
        succeeded_at: Time.current,
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: order.expires_at + 5.minutes
      )
      [ order, item, payment ]
    end

    def initiate_cancellation(key: "cancellation-#{SecureRandom.hex(5)}")
      Events::Cancellation::Initiate.call(
        event: @event,
        actor: @actor,
        attendee_reason: "The event will not proceed.",
        idempotency_key: key
      ).value
    end
  end
end
