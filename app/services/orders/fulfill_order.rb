# frozen_string_literal: true

module Orders
  # Completes the Orders-side fulfillment boundary after accepted payment.
  # Item fulfillment is marked in the same transaction as the one durable
  # outbox event; Ticketing and Finance consume that event in later roadmap
  # waves instead of Orders creating placeholder domain rows.
  class FulfillOrder < Core::BaseService
    def initialize(order:, payment:, idempotency_key: nil)
      @order = order
      @payment = payment
      @idempotency_key = idempotency_key || "orders-payment-fulfilled-#{payment.id}"
    end

    def call
      ActiveRecord::Base.transaction do
        order = Orders::Order.lock.find(@order.id)
        return success(order) if order.status == "fulfilled"
        return failure(fulfillment_error(:order_not_paid, code: "order_not_paid")) unless order.paid?

        items = Orders::OrderItem.lock.where(order_id: order.id).order(:id).to_a
        items.each do |item|
          item.update!(fulfillment_status: "fulfilled") unless item.fulfillment_status == "fulfilled"
        end
        order.update!(status: "fulfilled") unless order.status == "fulfilled"
        publish_fulfillment!(order, items)
        success(order)
      end
    rescue ActiveRecord::RecordInvalid => error
      failure(fulfillment_error(:fulfillment_failed, code: "fulfillment_failed", errors: error.record.errors.to_hash))
    end

    private

    attr_reader :order, :payment, :idempotency_key

    def publish_fulfillment!(locked_order, items)
      result = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.payment.fulfilled",
        aggregate: locked_order,
        payload: {
          order_id: locked_order.id,
          payment_id: payment.id,
          order_item_ids: items.map(&:id),
          event_id: locked_order.event_id
        },
        idempotency_key:
      )
      raise result.error if result.failure?
    end

    def fulfillment_error(key, code:, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.payments.fulfillment.errors.#{key}"),
        code:, status: :conflict, errors:
      )
    end
  end
end
