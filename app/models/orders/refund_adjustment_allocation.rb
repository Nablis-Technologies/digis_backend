# frozen_string_literal: true

module Orders
  # Signed reversal of one buyer-charged order adjustment. It snapshots the
  # original adjustment rather than consulting current Commercial policy.
  class RefundAdjustmentAllocation < Orders::ApplicationRecord
    self.table_name = "orders_refund_adjustment_allocations"

    belongs_to :refund_item,
               class_name: "Orders::RefundItem",
               inverse_of: :refund_adjustment_allocations
    belongs_to :order_adjustment,
               class_name: "Orders::OrderAdjustment",
               inverse_of: :refund_adjustment_allocations

    validates :refund_item, :order_adjustment, presence: true
    validates :amount_minor, numericality: { only_integer: true, other_than: 0 }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id refund_item_id order_adjustment_id amount_minor created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[refund_item order_adjustment]
    end
  end
end
