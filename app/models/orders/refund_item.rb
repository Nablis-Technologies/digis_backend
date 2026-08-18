# frozen_string_literal: true

module Orders
  # Immutable description of the order value being returned by one refund.
  # Provider submission and ticket/stock transitions are later commands; this
  # row remains the durable reconciliation boundary for both.
  class RefundItem < Orders::ApplicationRecord
    self.table_name = "orders_refund_items"

    belongs_to :refund, class_name: "Orders::Refund", inverse_of: :refund_items
    belongs_to :order_item, class_name: "Orders::OrderItem", inverse_of: :refund_items
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true
    belongs_to :event_date, class_name: "Events::EventDate", optional: true
    belongs_to :event_date_change, class_name: "Events::EventDateChange", optional: true

    has_many :refund_adjustment_allocations,
             class_name: "Orders::RefundAdjustmentAllocation",
             inverse_of: :refund_item,
             dependent: :restrict_with_exception

    validates :refund, :order_item, presence: true
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :subtotal_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id refund_id order_item_id ticket_id event_date_id event_date_change_id quantity
         subtotal_minor amount_minor restock reason created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[refund order_item ticket event_date event_date_change refund_adjustment_allocations]
    end
  end
end
