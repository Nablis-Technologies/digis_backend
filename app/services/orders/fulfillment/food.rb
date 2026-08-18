# frozen_string_literal: true

module Orders
  module Fulfillment
    # Completes the durable order-item boundary for food products without
    # turning a consumable voucher into a ticketing credential.
    class Food < Core::BaseService
      def initialize(order_item:, idempotency_key:)
        @order_item = order_item
        @idempotency_key = idempotency_key
      end

      def call
        success(@order_item)
      end
    end
  end
end
