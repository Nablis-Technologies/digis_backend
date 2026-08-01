# frozen_string_literal: true

module Catalog
  # A versioned buyer discount definition scoped to one event. Draft versions
  # may be edited; published and disabled versions are immutable.
  class Promotion < Catalog::ApplicationRecord
    self.table_name = "catalog_promotions"
    self.inheritance_column = nil

    TYPES = %w[percentage fixed].freeze
    STATUSES = %w[draft active disabled].freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :promotions
    belongs_to :supersedes_promotion,
               class_name: "Catalog::Promotion",
               optional: true,
               inverse_of: :superseding_promotions,
               foreign_key: :supersedes_promotion_id

    has_many :superseding_promotions,
             class_name: "Catalog::Promotion",
             foreign_key: :supersedes_promotion_id,
             inverse_of: :supersedes_promotion,
             dependent: :restrict_with_error
    has_many :promotion_codes,
             class_name: "Catalog::PromotionCode",
             inverse_of: :promotion,
             dependent: :destroy
    has_many :promotion_products,
             class_name: "Catalog::PromotionProduct",
             inverse_of: :promotion,
             dependent: :destroy
    has_many :event_products,
             through: :promotion_products,
             source: :event_product

    validates :event, presence: true
    validates :name, presence: true
    validates :version, numericality: { only_integer: true, greater_than: 0 }
    validates :type, presence: true, inclusion: { in: TYPES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :currency,
              presence: true,
              format: {
                with: /\A[A-Z]{3}\z/,
                message: ->(*_args) { I18n.t("catalog.promotion.errors.invalid_currency") }
              }
    validates :percentage_basis_points,
              numericality: {
                only_integer: true,
                greater_than: 0,
                less_than_or_equal_to: 10_000,
                message: ->(*_args) { I18n.t("catalog.promotion.errors.invalid_percentage_basis_points") }
              },
              allow_nil: true
    validates :fixed_amount_minor,
              numericality: {
                only_integer: true,
                greater_than_or_equal_to: 0,
                message: ->(*_args) { I18n.t("catalog.promotion.errors.invalid_fixed_amount") }
              },
              allow_nil: true
    validates :minimum_subtotal_minor,
              numericality: {
                only_integer: true,
                greater_than_or_equal_to: 0,
                message: ->(*_args) { I18n.t("catalog.promotion.errors.invalid_minimum_subtotal") }
              },
              allow_nil: true
    validates :maximum_discount_minor,
              numericality: {
                only_integer: true,
                greater_than: 0,
                message: ->(*_args) { I18n.t("catalog.promotion.errors.invalid_maximum_discount") }
              },
              allow_nil: true
    validates :redemption_limit,
              numericality: {
                only_integer: true,
                greater_than: 0,
                message: ->(*_args) { I18n.t("catalog.promotion.errors.invalid_redemption_limit") }
              },
              allow_nil: true
    validates :per_user_limit,
              numericality: {
                only_integer: true,
                greater_than: 0,
                message: ->(*_args) { I18n.t("catalog.promotion.errors.invalid_per_user_limit") }
              }
    validate :calculation_fields_match_type
    validate :window_order

    scope :drafts, -> { where(status: "draft") }
    scope :active, -> { where(status: "active") }
    scope :disabled, -> { where(status: "disabled") }
    scope :usable_at, lambda { |at|
      active
        .where("starts_at IS NULL OR starts_at <= ?", at)
        .where("ends_at IS NULL OR ends_at > ?", at)
    }

    def draft?
      status == "draft"
    end

    def active?
      status == "active"
    end

    def disabled?
      status == "disabled"
    end

    def usable_at?(at)
      active? && (starts_at.blank? || starts_at <= at) && (ends_at.blank? || ends_at > at)
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_id supersedes_promotion_id version name type
        percentage_basis_points fixed_amount_minor currency
        minimum_subtotal_minor maximum_discount_minor redemption_limit
        per_user_limit starts_at ends_at status lock_version created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event supersedes_promotion promotion_codes promotion_products event_products]
    end

    private

    def calculation_fields_match_type
      if type == "percentage" && percentage_basis_points.blank?
        errors.add(:percentage_basis_points, I18n.t("catalog.promotion.errors.invalid_percentage_basis_points"))
        return
      end
      if type == "fixed" && fixed_amount_minor.blank?
        errors.add(:fixed_amount_minor, I18n.t("catalog.promotion.errors.invalid_fixed_amount"))
        return
      end

      valid_percentage = type == "percentage" && fixed_amount_minor.nil?
      valid_fixed = type == "fixed" && percentage_basis_points.nil?
      return if valid_percentage || valid_fixed

      errors.add(:base, I18n.t("catalog.promotion.errors.calculation_exclusive"))
    end

    def window_order
      return if starts_at.blank? || ends_at.blank? || ends_at > starts_at

      errors.add(:ends_at, I18n.t("catalog.promotion.errors.invalid_window"))
    end
  end
end
