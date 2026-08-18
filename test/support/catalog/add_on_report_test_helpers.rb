# frozen_string_literal: true

require "digest"

module CatalogAddOnReportTestHelpers
  def setup_add_on_report_data
    @event = events_events(:ready_listing)
    @other_event = events_events(:draft_concert)
    @buyer = core_users(:attendee)
    @merchandise = create_report_product(event: @event, type: "merchandise", name: "Festival Shirt")
    @food = create_report_product(event: @event, type: "food", name: "Lunch Voucher")
    @other_event_product = create_report_product(event: @other_event, type: "merchandise", name: "Other Event Shirt")
    @refunded_item = create_report_item(product: @merchandise, quantity: 2, total_minor: 3_000)
    @second_item = create_report_item(product: @merchandise, quantity: 1, total_minor: 500)
    @food_item = create_report_item(product: @food, quantity: 1, total_minor: 800)
    create_report_item(product: @other_event_product, event: @other_event, quantity: 1, total_minor: 9_999)
    create_successful_refund(order_item: @refunded_item, amount_minor: 700)
  end

  private

  def create_report_product(event:, type:, name:)
    Catalog::EventProduct.create!(
      event:,
      name:,
      type:,
      status: "active",
      inventory_mode: "unlimited",
      schedule_change_refund_policy: "full_or_partial",
      min_per_order: 1
    )
  end

  def create_report_item(product:, event: product.event, quantity:, total_minor:,
    charge_currency: "ETB", settlement_currency: "ETB")
    order = Orders::Order.create!(
      event:,
      buyer_user: @buyer,
      sales_channel: "online",
      status: "draft",
      charge_currency:,
      commercial_signature: Digest::SHA256.hexdigest(SecureRandom.uuid),
      subtotal_minor: total_minor,
      discount_minor: 0,
      subsidy_minor: 0,
      fee_minor: 0,
      tax_minor: 0,
      adjustment_minor: 0,
      total_minor: total_minor,
      settlement_currency:,
      settlement_total_minor: total_minor,
      exchange_rate: 1,
      exchange_rate_source: "same_currency",
      expires_at: 1.hour.from_now,
      idempotency_key_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
      creation_request_digest: Digest::SHA256.hexdigest(SecureRandom.uuid)
    )
    item = order.order_items.create!(
      event_product: product,
      name_snapshot: product.name,
      type_snapshot: product.type,
      quantity:,
      admissions_per_unit_snapshot: nil,
      base_currency: charge_currency,
      base_unit_amount_minor: total_minor / quantity,
      charge_currency:,
      charge_unit_amount_minor: total_minor / quantity,
      exchange_rate: 1,
      discount_minor: 0,
      total_minor:,
      fulfillment_status: "fulfilled"
    )
    order.update_columns(status: "fulfilled", paid_at: Time.current)
    item.reload
  end

  def create_successful_refund(order_item:, amount_minor:)
    order = order_item.order
    payment = Orders::Payment.create!(
      order:,
      attempt_number: 1,
      provider: "chapa",
      payment_method: "telebirr",
      status: "succeeded",
      amount_minor: order.total_minor,
      currency: order.charge_currency,
      commercial_signature: order.commercial_signature,
      buyer_fee_minor: 0,
      organizer_fee_minor: 0,
      idempotency_key: "report-payment-#{SecureRandom.hex(5)}",
      provider_reference: "report-provider-#{SecureRandom.hex(5)}",
      accepted_at: Time.current,
      succeeded_at: Time.current,
      settlement_grace_minutes: 5,
      settlement_grace_expires_at: order.expires_at + 5.minutes
    )
    refund = Orders::Refund.create!(
      payment:,
      type: "item_refund",
      idempotency_key: "report-refund-#{SecureRandom.hex(5)}",
      amount_minor:,
      currency: order.charge_currency,
      status: "succeeded",
      reason_code: "event_cancellation"
    )
    Orders::RefundItem.create!(
      refund:,
      order_item:,
      quantity: 1,
      subtotal_minor: amount_minor,
      amount_minor:,
      reason: "event_cancellation"
    )
  end
end
