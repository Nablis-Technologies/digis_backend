# frozen_string_literal: true

module Commercial
  class FeeAmount < Commercial::ApplicationRecord
    include Commercial::DefinitionImmutable

    self.table_name = "commercial_fee_amounts"

    belongs_to :fee_component,
               class_name: "Commercial::FeeComponent",
               inverse_of: :fee_amounts

    before_validation :normalize_currency

    validates :fee_component, presence: true
    validates :currency,
              presence: true,
              format: { with: /\A[A-Z]{3}\z/ }
    validates :fixed_amount_minor, :minimum_minor, :maximum_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 },
              allow_nil: true
    validates :currency, uniqueness: { scope: :fee_component_id }
    validate :ordered_bounds

    def self.ransackable_attributes(_auth_object = nil)
      %w[id fee_component_id currency fixed_amount_minor minimum_minor maximum_minor created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[fee_component]
    end

    private

    def normalize_currency
      self.currency = currency.to_s.strip.upcase.presence
    end

    def ordered_bounds
      return if minimum_minor.blank? || maximum_minor.blank?
      return if maximum_minor >= minimum_minor

      errors.add(:maximum_minor, I18n.t("commercial.definitions.errors.maximum_below_minimum"))
    end
  end
end
