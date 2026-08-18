# frozen_string_literal: true

module Orders
  # One concurrency-safe promotion reservation for an order. The redemption
  # keeps the applied discount and entered-code identity as checkout evidence;
  # later state changes release or apply this row without rewriting history.
  class PromotionRedemption < Orders::ApplicationRecord
    self.table_name = "orders_promotion_redemptions"

    STATUSES = %w[reserved applied released expired].freeze

    belongs_to :order, class_name: "Orders::Order", inverse_of: :promotion_redemption
    belongs_to :promotion, class_name: "Catalog::Promotion"
    belongs_to :promotion_code,
               class_name: "Catalog::PromotionCode",
               optional: true
    belongs_to :user, class_name: "Core::User"

    validates :order, :promotion, :user, presence: true
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :discount_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :currency, presence: true, format: { with: /\A[A-Z]{3}\z/ }
    validates :idempotency_key, presence: true, uniqueness: true

    validate :state_metadata
    validate :promotion_scope
    validate :promotion_code_scope
    validate :buyer_scope
    validate :currency_matches_order

    scope :reserved, -> { where(status: "reserved") }
    scope :applied, -> { where(status: "applied") }
    scope :active_at, lambda { |at|
      where(status: "reserved").where("expires_at > ?", at)
    }

    def reserved? = status == "reserved"

    def applied? = status == "applied"

    def released? = %w[released expired].include?(status)

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id order_id promotion_id promotion_code_id user_id status discount_minor currency
        idempotency_key expires_at applied_at released_at created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[order promotion promotion_code user]
    end

    private

    def state_metadata
      if reserved?
        errors.add(:expires_at, :blank) if expires_at.blank?
        errors.add(:applied_at, :invalid) if applied_at.present?
        errors.add(:released_at, :invalid) if released_at.present?
      elsif applied?
        errors.add(:applied_at, :blank) if applied_at.blank?
        errors.add(:released_at, :invalid) if released_at.present?
      elsif status == "released"
        errors.add(:released_at, :blank) if released_at.blank?
        errors.add(:applied_at, :invalid) if applied_at.present?
      elsif status == "expired"
        errors.add(:expires_at, :blank) if expires_at.blank?
        errors.add(:applied_at, :invalid) if applied_at.present?
        errors.add(:released_at, :blank) if released_at.blank?
      end
    end

    def promotion_scope
      return if order.blank? || promotion.blank?
      return if order.event_id == promotion.event_id

      errors.add(:promotion, :invalid)
    end

    def promotion_code_scope
      return if promotion_code.blank? || promotion.blank?
      return if promotion_code.promotion_id == promotion.id

      errors.add(:promotion_code, :invalid)
    end

    def buyer_scope
      return if order.blank? || user.blank?
      return if order.buyer_user_id == user.id

      errors.add(:user, :invalid)
    end

    def currency_matches_order
      return if order.blank? || currency.blank?
      return if order.charge_currency == currency

      errors.add(:currency, :invalid)
    end
  end
end
