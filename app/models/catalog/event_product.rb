# frozen_string_literal: true

module Catalog
  # Anything an attendee can select, claim, or purchase. Ticket products
  # require exactly one `Ticketing::TicketType` row; all other product types
  # must not have one.
  class EventProduct < Catalog::ApplicationRecord
    self.table_name = "catalog_event_products"
    self.inheritance_column = nil

    PRODUCT_TYPES = %w[
      ticket parking merchandise food donation digital_addon other
    ].freeze
    REFUND_POLICIES = %w[full_or_partial full_only].freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :event_products
    has_one :ticket_type,
            class_name: "Ticketing::TicketType",
            inverse_of: :event_product,
            dependent: :destroy
    has_many :prices,
             class_name: "Catalog::ProductPrice",
             inverse_of: :event_product,
             dependent: :destroy

    validates :event, presence: true
    validates :name, presence: true
    validates :type, presence: true, inclusion: { in: PRODUCT_TYPES }
    validates :schedule_change_refund_policy,
              presence: true,
              inclusion: { in: REFUND_POLICIES }
    validates :min_per_order,
              numericality: { only_integer: true, greater_than_or_equal_to: 1 }
    validates :max_per_order,
              numericality: { only_integer: true, greater_than_or_equal_to: 1 },
              allow_nil: true
    validate :max_per_order_gte_min
    validate :sales_window_order
    validate :ticket_type_presence_policy

    scope :active, -> { where(active: true) }
    scope :visible, -> { where(hidden: false) }
    scope :tickets, -> { where(type: "ticket") }

    def ticket?
      type == "ticket"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_id name type active hidden allow_custom_price
        sales_start_at sales_end_at min_per_order max_per_order
        schedule_change_refund_policy sort_order created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event ticket_type]
    end

    private

    def max_per_order_gte_min
      return if max_per_order.blank? || min_per_order.blank?
      return if max_per_order >= min_per_order

      errors.add(:max_per_order, I18n.t("catalog.event_product.errors.max_per_order_gte_min"))
    end

    def sales_window_order
      return if sales_start_at.blank? || sales_end_at.blank?
      return if sales_end_at > sales_start_at

      errors.add(:sales_end_at, I18n.t("catalog.event_product.errors.sales_end_after_start"))
    end

    def ticket_type_presence_policy
      if ticket?
        errors.add(:ticket_type, I18n.t("catalog.event_product.errors.ticket_type_required")) if ticket_type.blank?
      else
        errors.add(:ticket_type, I18n.t("catalog.event_product.errors.ticket_type_not_allowed")) if ticket_type.present?
      end
    end
  end
end
