# frozen_string_literal: true

module Orders
  # Buyer-safe immutable product snapshot for checkout responses and receipts.
  class OrderItemSerializer < ActiveModel::Serializer
    attributes :id, :event_product_id, :name_snapshot, :type_snapshot, :quantity,
               :charge_currency, :charge_unit_amount_minor, :discount_minor,
               :total_minor, :fulfillment_status
  end
end
