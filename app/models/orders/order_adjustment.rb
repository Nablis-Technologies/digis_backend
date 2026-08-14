# frozen_string_literal: true

module Orders
  # Immutable itemization of buyer and organizer money. It snapshots the
  # resolved commercial component instead of retaining a live pricing rule;
  # after payment starts even direct SQL writers are blocked by the migration's
  # database trigger.
  class OrderAdjustment < Orders::ApplicationRecord
    self.table_name = "orders_order_adjustments"
    self.inheritance_column = nil

    TYPES = %w[
      discount service_fee platform_fee processing_fee subsidy resale_platform_fee tax manual_adjustment
    ].freeze
    CHARGED_TO = %w[buyer organizer].freeze
    REFUND_POLICIES = %w[refundable event_cancellation_only nonrefundable].freeze
    CALCULATION_TYPES = %w[explicit_zero percentage fixed blended tiered].freeze
    BASIS_TYPES = Commercial::FeeComponent::BASIS_TYPES
    FUNDED_BY = %w[buyer organizer platform].freeze
    SOURCE_TYPES = %w[Catalog::Promotion Commercial::FeeComponent].freeze
    COMMERCIAL_TYPES = %w[service_fee platform_fee processing_fee subsidy resale_platform_fee].freeze
    RESOLUTION_EVIDENCE_KEYS = %w[scope tier window rounding explanation].freeze
    IMMUTABLE_ORDER_STATUSES = Orders::Order::IMMUTABLE_STATUSES
    SNAPSHOT_ATTRIBUTES = %w[
      order_id order_item_id type label charged_to amount_minor currency refund_policy
      calculation_type basis_type basis_minor rate_bps fixed_amount_minor minimum_minor maximum_minor
      funded_by source_type source_id resolution_evidence
    ].freeze

    belongs_to :order, class_name: "Orders::Order", inverse_of: :order_adjustments
    belongs_to :order_item,
               class_name: "Orders::OrderItem",
               optional: true,
               inverse_of: :order_adjustments
    has_many :refund_adjustment_allocations,
             class_name: "Orders::RefundAdjustmentAllocation",
             inverse_of: :order_adjustment,
             dependent: :restrict_with_exception

    before_validation :normalize_currency
    before_destroy :prevent_destroy_if_immutable

    validates :order, presence: true
    validates :type, :charged_to, :refund_policy, :currency, presence: true
    validates :type, inclusion: { in: TYPES }
    validates :charged_to, inclusion: { in: CHARGED_TO }
    validates :refund_policy, inclusion: { in: REFUND_POLICIES }
    validates :calculation_type, inclusion: { in: CALCULATION_TYPES }, allow_nil: true
    validates :basis_type, inclusion: { in: BASIS_TYPES }, allow_nil: true
    validates :funded_by, inclusion: { in: FUNDED_BY }, allow_nil: true
    validates :source_type, inclusion: { in: SOURCE_TYPES }, allow_nil: true
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :amount_minor, numericality: { only_integer: true }
    validates :basis_minor, :rate_bps, :fixed_amount_minor, :minimum_minor, :maximum_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 },
              allow_nil: true
    validates :rate_bps, numericality: { less_than_or_equal_to: 10_000 }, allow_nil: true
    validates :label, presence: true

    validate :amount_sign
    validate :commercial_shape
    validate :calculation_snapshot_shape
    validate :source_pair
    validate :resolution_evidence_shape
    validate :order_item_scope
    validate :currency_matches_order
    validate :snapshot_immutable

    def subsidy? = type == "subsidy"

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id order_id order_item_id type label charged_to amount_minor currency refund_policy
        calculation_type basis_type basis_minor rate_bps fixed_amount_minor minimum_minor maximum_minor
        funded_by source_type source_id created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[order order_item]
    end

    private

    def normalize_currency
      self.currency = currency.to_s.strip.upcase.presence
    end

    def amount_sign
      return if amount_minor.blank?
      return if type == "manual_adjustment"

      expected_negative = %w[discount subsidy].include?(type)
      valid = expected_negative ? amount_minor.negative? : amount_minor >= 0
      errors.add(:amount_minor, :invalid) unless valid
    end

    def commercial_shape
      if COMMERCIAL_TYPES.include?(type)
        errors.add(:funded_by, :blank) if funded_by.blank?
        errors.add(:calculation_type, :blank) if calculation_type.blank?
        errors.add(:source_type, :blank) if source_type.blank?
        errors.add(:source_id, :blank) if source_id.blank?
      end
      errors.add(:funded_by, :invalid) if subsidy? && funded_by != "platform"
      errors.add(:funded_by, :invalid) if funded_by == "platform" && !subsidy?

      if %w[percentage blended tiered].include?(calculation_type) && basis_type.blank?
        errors.add(:basis_type, :blank)
      elsif %w[explicit_zero fixed].include?(calculation_type) && basis_type.present?
        errors.add(:basis_type, :invalid)
      end

      if %w[percentage blended].include?(calculation_type) && rate_bps.blank?
        errors.add(:rate_bps, :blank)
      elsif %w[explicit_zero fixed tiered].include?(calculation_type) && rate_bps.present?
        errors.add(:rate_bps, :invalid)
      end
    end

    def calculation_snapshot_shape
      case calculation_type
      when "fixed"
        errors.add(:fixed_amount_minor, :blank) if fixed_amount_minor.blank?
        errors.add(:basis_minor, :invalid) if basis_minor.present?
      when "blended"
        errors.add(:fixed_amount_minor, :blank) if fixed_amount_minor.blank?
      when "explicit_zero"
        if basis_minor.present? || fixed_amount_minor.present? || minimum_minor.present? || maximum_minor.present?
          errors.add(:calculation_type, :invalid)
        end
      end
    end

    def source_pair
      return if source_type.present? == source_id.present?

      errors.add(source_type.present? ? :source_id : :source_type, :blank)
    end

    def resolution_evidence_shape
      return if resolution_evidence.blank?
      return errors.add(:resolution_evidence, :invalid) unless resolution_evidence.is_a?(Hash)

      unknown_keys = resolution_evidence.stringify_keys.keys - RESOLUTION_EVIDENCE_KEYS
      errors.add(:resolution_evidence, :invalid) if unknown_keys.any?
    end

    def order_item_scope
      return if order_item_id.blank? || order_id.blank?
      return if association(:order_item).loaded? && order_item&.order_id == order_id
      return if Orders::OrderItem.where(id: order_item_id, order_id:).exists?

      errors.add(:order_item, :invalid)
    end

    def currency_matches_order
      return if order_id.blank? || currency.blank?
      return if association(:order).loaded? && order&.charge_currency == currency
      return if Orders::Order.where(id: order_id).pick(:charge_currency) == currency

      errors.add(:currency, :invalid)
    end

    def snapshot_immutable
      order_status = if association(:order).loaded?
        order&.status
      else
        Orders::Order.where(id: order_id).pick(:status)
      end
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
