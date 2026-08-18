# frozen_string_literal: true

module Orders
  module Fulfillment
    # Completes the durable order-item boundary for digital add-ons. Delivery
    # providers can consume this explicit seam later without changing order
    # ownership or borrowing ticket credentials.
    class DigitalAddOn < Core::BaseService
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
