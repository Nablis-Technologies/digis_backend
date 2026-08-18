# frozen_string_literal: true

module Orders
  module Fulfillment
    # Completes the durable order-item boundary for donations. The immutable
    # order-item amount remains the accounting fact; this handler adds no
    # access, inventory, QR, or PNR behavior.
    class Donation < Core::BaseService
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
