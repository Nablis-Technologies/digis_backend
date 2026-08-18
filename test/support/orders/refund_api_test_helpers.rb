# frozen_string_literal: true

module Orders
  # Builds a persisted accepted payment and refund so API tests can focus on
  # authorization and serialization rather than reimplementing checkout setup.
  module RefundApiTestHelpers
    private

    def create_api_refund(buyer: core_users(:attendee), event: events_events(:ready_listing))
      order = Orders::Order.create!(
        event:, buyer_user: buyer, sales_channel: "online", status: "draft",
        charge_currency: "ETB", commercial_signature: "a" * 64,
        subtotal_minor: 1_000, discount_minor: 0, subsidy_minor: 0, fee_minor: 0,
        tax_minor: 0, adjustment_minor: 0, total_minor: 1_000,
        settlement_currency: "ETB", settlement_total_minor: 1_000, exchange_rate: 1,
        exchange_rate_source: "same_currency", exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now, idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      product = Catalog::EventProduct.create!(
        event:, name: "Refund API product #{SecureRandom.hex(4)}", type: "merchandise",
        status: "active", inventory_mode: "unlimited"
      )
      item = Orders::OrderItem.create!(
        order:, event_product: product, name_snapshot: product.name, type_snapshot: "merchandise",
        quantity: 1, base_currency: "ETB", base_unit_amount_minor: 1_000,
        charge_currency: "ETB", charge_unit_amount_minor: 1_000, exchange_rate: 1,
        discount_minor: 0, total_minor: 1_000, fulfillment_status: "fulfilled"
      )
      order.update!(status: "fulfilled", paid_at: Time.current)
      payment = Orders::Payment.create!(
        order:, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 1_000, currency: "ETB",
        commercial_signature: order.commercial_signature, buyer_fee_minor: 0, organizer_fee_minor: 0,
        idempotency_key: "refund-api-payment-#{SecureRandom.hex(6)}",
        provider_reference: "refund-api-provider-#{SecureRandom.hex(4)}",
        accepted_at: Time.current, succeeded_at: Time.current,
        settlement_grace_minutes: 5, settlement_grace_expires_at: order.expires_at + 5.minutes
      )
      refund = Orders::Refund.create!(
        payment:, type: "item_refund", idempotency_key: "refund-api-#{SecureRandom.hex(6)}",
        amount_minor: 1_000, currency: "ETB", status: "succeeded",
        reason_code: "event_cancellation", provider_reference: "refund-provider-reference"
      )
      Orders::RefundItem.create!(
        refund:, order_item: item, quantity: 1, subtotal_minor: 1_000, amount_minor: 1_000
      )
      refund
    end
  end
end
