# frozen_string_literal: true

module Orders
  # Payer-only gift delivery status and redelivery controls.
  class GiftPurchasesController < Orders::ApplicationController
    before_action :set_no_store
    before_action :ensure_idempotency_key_present, only: :resend

    def index
      order = Orders::Order.find(params.require(:order_id))
      authorize order, :show?
      gifts = Orders::GiftPurchase.joins(:order_item)
        .where(orders_order_items: { order_id: order.id })
        .includes(order_item: :order)
        .order(:created_at, :id)
      gifts.each { |gift| authorize gift, :show? }

      render_success(data: gifts.map(&:payer_status_payload))
    end

    def resend
      order = Orders::Order.find(params.require(:order_id))
      gift = Orders::GiftPurchase.joins(:order_item)
        .where(orders_order_items: { order_id: order.id })
        .includes(order_item: { order: :event })
        .find_by(id: params[:id])
      return render_gift_not_found unless gift

      authorize gift, :resend?
      result = Orders::GiftPurchases::Resend.call(
        gift_purchase: gift,
        actor: current_user,
        idempotency_key:
      )
      return render_service_result(result) if result.failure?

      render_success(data: result.value.payer_status_payload)
    end

    private

    def set_no_store
      response.set_header("Cache-Control", "no-store")
    end

    def render_gift_not_found
      render_error(
        I18n.t("errors.not_found", model: "gift purchase"),
        status: :not_found,
        code: "gift_purchase_not_found"
      )
    end
  end
end
