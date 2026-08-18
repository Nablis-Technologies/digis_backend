# frozen_string_literal: true

module Orders
  module Fulfillment
    # Marks one paid noncredential order item fulfilled exactly once. The item
    # row is the durable idempotency boundary: no parallel fulfillment table,
    # partial quantity counter, QR, or PNR is introduced for these products.
    class FulfillAddOn < Core::BaseService
      def initialize(order_item:, idempotency_key:)
        @order_item = order_item
        @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
      rescue ArgumentError => error
        @initialization_error = error
      end

      def call
        return failure(error(:invalid_idempotency_key)) if @initialization_error

        ActiveRecord::Base.transaction do
          item = locked_order_item
          return success(item) if item.fulfilled?
          return failure(error(:item_not_pending)) unless item.fulfillment_status == "pending"
          return failure(error(:order_not_paid)) unless item.order.paid?

          validation = Catalog::AddOns::ValidateProduct.call(product: item.event_product)
          return failure(validation.error) if validation.failure?

          handler = AddOnRegistry.fetch(item.event_product.type)
          return failure(error(:unsupported_add_on_type)) unless handler

          result = handler.call(order_item: item, idempotency_key: @idempotency_key.to_s)
          return failure(result.error) if result.failure?

          item.update!(fulfillment_status: "fulfilled")
          success(item)
        end
      rescue ActiveRecord::RecordNotFound
        failure(error(:order_item_not_found, status: :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:fulfillment_failed, errors: exception.record.errors.to_hash))
      end

      private

      def locked_order_item
        Orders::OrderItem.includes(:order, :event_product).lock.find(@order_item.id)
      end

      def error(key, status: :conflict, errors: nil)
        Core::BusinessError.new(
          I18n.t("orders.fulfillment.add_ons.errors.#{key}"),
          code: key,
          status:,
          errors:
        )
      end
    end
  end
end
