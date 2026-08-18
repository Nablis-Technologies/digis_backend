# frozen_string_literal: true

module Orders
  module Fulfillment
    # Completes the durable order-item boundary for merchandise. Physical
    # picking, delivery, and inventory operations belong to later integrations;
    # this command never creates a ticket or credential.
    class Merchandise < Core::BaseService
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
