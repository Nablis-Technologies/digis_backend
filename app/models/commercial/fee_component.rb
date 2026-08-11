# frozen_string_literal: true

module Commercial
  class FeeComponent < Commercial::ApplicationRecord
    include Commercial::DefinitionImmutable

    self.table_name = "commercial_fee_components"

    COMPONENT_TYPES = %w[
      platform_commission buyer_service_fee processing_cost_recovery
      platform_subsidy resale_platform_fee
    ].freeze
    CALCULATION_TYPES = %w[explicit_zero percentage fixed blended tiered].freeze
    CHARGED_TO = %w[buyer organizer].freeze
    FUNDED_BY = %w[buyer organizer platform].freeze
    REFUND_POLICIES = %w[refundable event_cancellation_only nonrefundable].freeze
    BASIS_TYPES = %w[
      item_face_value item_net_value_after_organizer_promotion
      eligible_order_subtotal resale_acquisition_amount accepted_paid_units accepted_gross
    ].freeze
    SALE_CONTEXTS = %w[primary resale].freeze
    PROVIDERS = %w[chapa stripe].freeze
    PAYMENT_METHODS = %w[telebirr card bank].freeze
    SALES_CHANNELS = %w[online walk_up resale].freeze
    PRODUCT_TYPES = Catalog::EventProduct::PRODUCT_TYPES

    belongs_to :fee_schedule_version,
               class_name: "Commercial::FeeScheduleVersion",
               inverse_of: :fee_components
    belongs_to :event_product,
               class_name: "Catalog::EventProduct",
               optional: true
    has_many :fee_amounts,
             class_name: "Commercial::FeeAmount",
             inverse_of: :fee_component,
             dependent: :restrict_with_exception
    has_many :fee_tiers,
             class_name: "Commercial::FeeTier",
             inverse_of: :fee_component,
             dependent: :restrict_with_exception

    before_validation :normalize_scope_currency

    validates :fee_schedule_version, presence: true
    validates :component_type, presence: true, inclusion: { in: COMPONENT_TYPES }
    validates :calculation_type, presence: true, inclusion: { in: CALCULATION_TYPES }
    validates :charged_to, presence: true, inclusion: { in: CHARGED_TO }
    validates :funded_by, presence: true, inclusion: { in: FUNDED_BY }
    validates :refund_policy, presence: true, inclusion: { in: REFUND_POLICIES }
    validates :basis_type, inclusion: { in: BASIS_TYPES }, allow_nil: true
    validates :rate_bps, numericality: { only_integer: true, in: 0..10_000 }, allow_nil: true
    validates :event_product, presence: true, if: -> { event_product_id.present? }
    validates :product_type, inclusion: { in: PRODUCT_TYPES }, allow_nil: true
    validates :sale_context, inclusion: { in: SALE_CONTEXTS }, allow_nil: true
    validates :provider, inclusion: { in: PROVIDERS }, allow_nil: true
    validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_nil: true
    validates :sales_channel, inclusion: { in: SALES_CHANNELS }, allow_nil: true
    validates :currency,
              format: { with: /\A[A-Z]{3}\z/ },
              allow_nil: true
    validates :label, presence: true

    validate :calculation_shape
    validate :subsidy_shape
    validate :offset_shape

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id fee_schedule_version_id component_type calculation_type charged_to
        funded_by basis_type rate_bps refund_policy event_product_id product_type
        sale_context provider payment_method sales_channel currency created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[fee_schedule_version event_product fee_amounts fee_tiers]
    end

    private

    def normalize_scope_currency
      self.currency = currency.to_s.strip.upcase.presence
    end

    def calculation_shape
      if %w[percentage blended tiered].include?(calculation_type) && basis_type.blank?
        errors.add(:basis_type, I18n.t("commercial.definitions.errors.basis_required"))
      elsif %w[explicit_zero fixed].include?(calculation_type) && basis_type.present?
        errors.add(:basis_type, I18n.t("commercial.definitions.errors.basis_forbidden"))
      end

      if %w[percentage blended].include?(calculation_type) && rate_bps.blank?
        errors.add(:rate_bps, I18n.t("commercial.definitions.errors.rate_required"))
      elsif %w[explicit_zero fixed tiered].include?(calculation_type) && rate_bps.present?
        errors.add(:rate_bps, I18n.t("commercial.definitions.errors.rate_forbidden"))
      end
    end

    def subsidy_shape
      if component_type == "platform_subsidy"
        errors.add(:funded_by, I18n.t("commercial.definitions.errors.subsidy_funded_by")) unless funded_by == "platform"
        errors.add(:offset_component_type, I18n.t("commercial.definitions.errors.subsidy_offset_required")) if offset_component_type.blank?
      elsif funded_by == "platform"
        errors.add(:funded_by, I18n.t("commercial.definitions.errors.platform_funding_only_subsidy"))
      end
    end

    def offset_shape
      return if offset_component_type.blank? || component_type == "platform_subsidy"

      errors.add(:offset_component_type, I18n.t("commercial.definitions.errors.offset_only_subsidy"))
    end
  end
end
