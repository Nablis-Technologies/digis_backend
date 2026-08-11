# frozen_string_literal: true

module Orders
  # Immutable product and currency snapshot belonging to one event-scoped
  # order. Fulfillment status remains mutable for later ticket/refund flows;
  # product identity and money never change after payment starts.
  class OrderItem < Orders::ApplicationRecord
    self.table_name = "orders_order_items"

    FULFILLMENT_STATUSES = %w[pending fulfilled cancelled refunded].freeze
    PRODUCT_TYPES = Catalog::EventProduct::PRODUCT_TYPES
    IMMUTABLE_ORDER_STATUSES = Orders::Order::IMMUTABLE_STATUSES
    SNAPSHOT_ATTRIBUTES = %w[
      order_id event_product_id registration_id resale_listing_id name_snapshot type_snapshot
      quantity admissions_per_unit_snapshot base_currency base_unit_amount_minor charge_currency
      charge_unit_amount_minor exchange_rate discount_minor total_minor
    ].freeze

    belongs_to :order, class_name: "Orders::Order", inverse_of: :order_items
    belongs_to :event_product, class_name: "Catalog::EventProduct"
    belongs_to :registration,
               class_name: "Ticketing::Registration",
               optional: true

    has_many :order_adjustments,
             class_name: "Orders::OrderAdjustment",
             inverse_of: :order_item,
             dependent: :restrict_with_exception

    before_validation :normalize_currencies
    before_destroy :prevent_destroy_if_immutable

    validates :order, :event_product, presence: true
    validates :name_snapshot, :type_snapshot, :base_currency, :charge_currency, presence: true
    validates :type_snapshot, inclusion: { in: PRODUCT_TYPES }
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :base_unit_amount_minor, :charge_unit_amount_minor, :discount_minor, :total_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :admissions_per_unit_snapshot,
              numericality: { only_integer: true, greater_than: 0 },
              allow_nil: true
    validates :fulfillment_status,
              presence: true,
              inclusion: { in: FULFILLMENT_STATUSES }
    validates :exchange_rate,
              numericality: { greater_than: 0 },
              allow_nil: true
    validates :base_currency, :charge_currency,
              format: { with: /\A[A-Z]{3}\z/ }

    validate :product_belongs_to_order_event
    validate :registration_belongs_to_order_event
    validate :snapshot_shape
    validate :product_type_matches_snapshot
    validate :charge_currency_matches_order
    validate :exchange_rate_shape
    validate :snapshot_immutable

    scope :pending, -> { where(fulfillment_status: "pending") }

    def fulfilled? = fulfillment_status == "fulfilled"

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id order_id event_product_id registration_id resale_listing_id name_snapshot type_snapshot
        quantity admissions_per_unit_snapshot base_currency base_unit_amount_minor charge_currency
        charge_unit_amount_minor exchange_rate discount_minor total_minor fulfillment_status
        created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[order event_product registration order_adjustments]
    end

    private

    def normalize_currencies
      self.base_currency = base_currency.to_s.strip.upcase.presence
      self.charge_currency = charge_currency.to_s.strip.upcase.presence
    end

    def product_belongs_to_order_event
      return if order_id.blank? || event_product_id.blank?

      order_event_id = Orders::Order.where(id: order_id).pick(:event_id) || order&.event_id
      product_event_id = Catalog::EventProduct.where(id: event_product_id).pick(:event_id) || event_product&.event_id
      return if order_event_id.present? && order_event_id == product_event_id

      errors.add(:event_product, :invalid)
    end

    def registration_belongs_to_order_event
      return if registration_id.blank? || order_id.blank?

      order_event_id = Orders::Order.where(id: order_id).pick(:event_id) || order&.event_id
      registration_event_id = Ticketing::Registration.where(id: registration_id).pick(:event_id) || registration&.event_id
      return if order_event_id.present? && order_event_id == registration_event_id

      errors.add(:registration, :invalid)
    end

    def snapshot_shape
      if type_snapshot == "ticket" && admissions_per_unit_snapshot.blank?
        errors.add(:admissions_per_unit_snapshot, :blank)
      elsif type_snapshot.present? && type_snapshot != "ticket" && admissions_per_unit_snapshot.present?
        errors.add(:admissions_per_unit_snapshot, :invalid)
      end
    end

    def product_type_matches_snapshot
      return if event_product_id.blank? || type_snapshot.blank?

      product_type = Catalog::EventProduct.where(id: event_product_id).pick(:type) || event_product&.type
      return if product_type.blank? || product_type == type_snapshot

      errors.add(:type_snapshot, :invalid)
    end

    def charge_currency_matches_order
      return if order_id.blank? || charge_currency.blank?

      order_currency = Orders::Order.where(id: order_id).pick(:charge_currency) || order&.charge_currency
      return if order_currency.blank? || charge_currency == order_currency

      errors.add(:charge_currency, :invalid)
    end

    def exchange_rate_shape
      return if base_currency.blank? || charge_currency.blank?

      if base_currency == charge_currency
        errors.add(:exchange_rate, :invalid) if exchange_rate.present? && exchange_rate != 1
      elsif exchange_rate.blank?
        errors.add(:exchange_rate, :blank)
      end
    end

    def snapshot_immutable
      order_status = Orders::Order.where(id: order_id).pick(:status) || order&.status
      return unless IMMUTABLE_ORDER_STATUSES.include?(order_status)

      unless persisted?
        errors.add(:order, :immutable)
        return
      end

      SNAPSHOT_ATTRIBUTES.each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end

    def prevent_destroy_if_immutable
      return unless IMMUTABLE_ORDER_STATUSES.include?(Orders::Order.where(id: order_id).pick(:status))

      raise ActiveRecord::ReadOnlyRecord, I18n.t("errors.messages.immutable")
    end
  end
end
