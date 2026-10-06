# frozen_string_literal: true

module Orders
  # Completes the Orders-side fulfillment boundary after accepted payment.
  # Item fulfillment is marked in the same transaction as the durable handoff.
  # Resale orders use Marketplace's existing-package transfer boundary instead
  # of the normal Ticketing issuance event, so a resale never creates a second
  # primary ticket.
  class FulfillOrder < Core::BaseService
    def initialize(order:, payment:, idempotency_key: nil)
      @order = order
      @payment = payment
      @idempotency_key = idempotency_key || default_idempotency_key
    end

    def call
      outcome = nil
      ActiveRecord::Base.transaction do
        CheckoutLock.acquire_for_order!(order_id: @order.id)
        order = Orders::Order.lock.find(@order.id)
        if order.status == "fulfilled" &&
          (order.sales_channel != "resale" || resale_sale_exists?(order))
          outcome = success(order)
          next
        end
        return failure(fulfillment_error(:order_not_paid, code: "order_not_paid")) unless order.paid?
        return failure(fulfillment_error(:order_not_paid, code: "order_not_paid")) if payment.nil? && !order.total_minor.zero?
        return failure(fulfillment_error(:order_not_paid, code: "order_not_paid")) if payment.nil? && order.sales_channel == "resale"

        if order.sales_channel == "resale"
          outcome = fulfill_resale_order(order)
          raise ActiveRecord::Rollback if outcome.failure?
          next
        end

        items = Orders::OrderItem.lock.where(order_id: order.id).order(:id).to_a
        items.each do |item|
          item.update!(fulfillment_status: "fulfilled") unless item.fulfillment_status == "fulfilled"
        end
        order.update!(status: "fulfilled") unless order.status == "fulfilled"
        gift_result = activate_gifts!(items)
        if gift_result.failure?
          outcome = failure(gift_result.error)
          raise ActiveRecord::Rollback
        end
        gift_purchases = gift_result.value
        publish_fulfillment!(order, items, gift_purchases:)
        outcome = success(order)
      end
      outcome
    rescue ActiveRecord::RecordInvalid => error
      failure(fulfillment_error(:fulfillment_failed, code: "fulfillment_failed", errors: error.record.errors.to_hash))
    end

    private

    attr_reader :order, :payment, :idempotency_key

    def default_idempotency_key
      return "orders-free-fulfilled-#{order.id}" if payment.nil?

      "orders-payment-fulfilled-#{payment.id}"
    end

    def resale_sale_exists?(locked_order)
      return false unless locked_order.sales_channel == "resale"

      Marketplace::ResaleSale.joins(:buyer_order).where(
        buyer_order_id: locked_order.id,
        accepted_payment_id: payment.id
      ).exists?
    end

    def fulfill_resale_order(locked_order)
      listing = Marketplace::ResaleListing.lock.find_by(reserved_order_id: locked_order.id)
      return failure(fulfillment_error(:fulfillment_failed, code: "resale_listing_not_found")) unless listing

      result = Marketplace::FulfillSale.call(listing:, order: locked_order, payment:)
      return failure(result.error) if result.failure?

      success(locked_order.reload)
    end

    def activate_gifts!(items)
      gifts = Orders::GiftPurchase.where(order_item_id: items.map(&:id)).order(:id).lock.to_a
      now = Time.current
      gifts.each do |gift|
        next if gift.status.in?(%w[ready claimed])
        return failure(fulfillment_error(:gift_purchase_unavailable, code: "gift_purchase_unavailable")) unless gift.status == "pending_payment"

        if gift.expires_at <= now
          # A delayed payment after event end expires the unused gift normally;
          # it must not queue an already-unclaimable recipient link.
          result = GiftPurchases::Expire.call(gift_purchase: gift, at: now, after_payment: true)
          return failure(result.error) if result.failure?

          gift.reload
          next
        end

        gift.update!(status: "ready", ready_at: now)
        publish_gift_ready!(gift)
      end
      success(gifts)
    end

    def publish_gift_ready!(gift)
      result = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.gift_purchase.ready",
        aggregate: gift,
        payload: { gift_purchase_id: gift.id },
        idempotency_key: "orders-gift-purchase-ready-#{gift.id}"
      )
      raise result.error if result.failure?
    end

    def publish_fulfillment!(locked_order, items, gift_purchases:)
      gift_order_item_ids = gift_purchases.map(&:order_item_id)
      result = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.payment.fulfilled",
        aggregate: locked_order,
        payload: {
          order_id: locked_order.id,
          payment_id: payment&.id,
          order_item_ids: items.map(&:id),
          gift_order_item_ids:,
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
