# frozen_string_literal: true

module Orders
  # Serializes the buyer's order view. Associations are deliberately filtered
  # to item snapshots and buyer adjustments; settlement and provider evidence
  # belong to private operational surfaces introduced by later tasks.
  class OrderSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :event_id, :status, :sales_channel, :charge_currency,
               :subtotal_minor, :discount_minor, :subsidy_minor, :fee_minor,
               :tax_minor, :adjustment_minor, :total_minor, :expires_at, :paid_at,
               :created_at, :updated_at

    has_many :order_items, key: :items, serializer: Orders::OrderItemSerializer
    has_many :buyer_adjustments, key: :adjustments, serializer: Orders::OrderAdjustmentSerializer

    def buyer_adjustments
      object.order_adjustments.select { |adjustment| adjustment.charged_to == "buyer" }
    end
  end
end
