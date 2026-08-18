# frozen_string_literal: true

module Commercial
  class FeeTier < Commercial::ApplicationRecord
    include Commercial::DefinitionImmutable

    self.table_name = "commercial_fee_tiers"

    METRIC_TYPES = %w[accepted_paid_units accepted_gross].freeze
    WINDOW_TYPES = %w[event calendar_month calendar_quarter calendar_year agreement_term].freeze

    belongs_to :fee_component,
               class_name: "Commercial::FeeComponent",
               inverse_of: :fee_tiers

    before_validation :normalize_currency

    validates :fee_component, presence: true
    validates :position, presence: true, numericality: { only_integer: true, greater_than: 0 }
    validates :metric_type, presence: true, inclusion: { in: METRIC_TYPES }
    validates :window_type, presence: true, inclusion: { in: WINDOW_TYPES }
    validates :starts_at_value, presence: true,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :currency,
              format: { with: /\A[A-Z]{3}\z/ },
              allow_nil: true
    validates :rate_bps, :fixed_amount_minor, :minimum_minor, :maximum_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 },
              allow_nil: true
    validates :position, uniqueness: { scope: :fee_component_id }
    validate :gross_currency
    validate :ordered_bounds

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id fee_component_id position metric_type window_type currency starts_at_value
        rate_bps fixed_amount_minor minimum_minor maximum_minor created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[fee_component]
    end

    private

    def normalize_currency
      self.currency = currency.to_s.strip.upcase.presence
    end

    def gross_currency
      return unless metric_type == "accepted_gross" && currency.blank?

      errors.add(:currency, I18n.t("commercial.definitions.errors.gross_currency_required"))
    end

    def ordered_bounds
      return if minimum_minor.blank? || maximum_minor.blank?
      return if maximum_minor >= minimum_minor

      errors.add(:maximum_minor, I18n.t("commercial.definitions.errors.maximum_below_minimum"))
    end
  end
end
