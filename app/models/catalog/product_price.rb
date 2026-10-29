# frozen_string_literal: true

module Catalog
  # A price for a product, optionally scoped to a ticket type. Prices carry an
  # active window; overlapping windows for the same product/type/currency are
  # rejected both at the model layer (friendly error) and via a PostgreSQL
  # exclusion constraint (hard guarantee). `type` distinguishes an exchange-
  # converted base price from a fixed override in a specific currency.
  class ProductPrice < Catalog::ApplicationRecord
    self.table_name = "catalog_product_prices"
    self.inheritance_column = nil
    TYPES = %w[base override].freeze

    belongs_to :event_product, class_name: "Catalog::EventProduct"
    belongs_to :ticket_type, class_name: "Ticketing::TicketType", optional: true

    validates :event_product, presence: true
    validates :currency,
              presence: true,
              format: { with: /\A[A-Z]{3}\z/, allow_blank: true,
                        message: ->(*_args) { I18n.t("catalog.product_price.errors.currency_format") } }
    validates :amount_minor,
              presence: true,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :type, presence: true, inclusion: { in: TYPES }
    validates :active_from, presence: true
    validate :no_overlapping_active_range

    scope :active_at, ->(at) { where("active_from <= ?", at).where("(active_to IS NULL OR active_to > ?)", at) }
    scope :for_currency, ->(currency) { where(currency: currency.to_s.upcase) }
    scope :overrides, -> { where(type: "override") }
    scope :base, -> { where(type: "base") }

    def self.active_at_in_memory(prices, at:)
      Array(prices).sort_by { |price| price.id.to_s }.select do |price|
        price.active_from <= at && (price.active_to.nil? || price.active_to > at)
      end
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_product_id ticket_type_id currency amount_minor type
        active_from active_to created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event_product ticket_type]
    end

    private

    def no_overlapping_active_range
      return if active_from.blank? || event_product_id.blank?

      overlap = self.class
        .where(event_product_id: event_product_id)
        .where(currency: currency.to_s.upcase)
        .where("ticket_type_id IS NOT DISTINCT FROM ?", ticket_type_id)
        .where("tstzrange(active_from, active_to, '[]') && tstzrange(?, ?, '[]')", active_from, active_to)
      overlap = overlap.where.not(id: id) if persisted?

      return unless overlap.exists?

      errors.add(:active_range, I18n.t("catalog.product_price.errors.active_range_overlap"))
    end
  end
end
