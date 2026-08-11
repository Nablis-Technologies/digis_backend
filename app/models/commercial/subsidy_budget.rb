# frozen_string_literal: true

module Commercial
  # Defines hard platform-funded subsidy capacity for one owner and
  # currency. The database owns the hard cap; the future order-linked
  # reservation command will use lock_version while updating these counters.
  class SubsidyBudget < Commercial::ApplicationRecord
    self.table_name = "commercial_subsidy_budgets"

    belongs_to :assignment,
               class_name: "Commercial::Assignment",
               optional: true,
               inverse_of: :subsidy_budgets
    belongs_to :program,
               class_name: "Commercial::Program",
               optional: true,
               inverse_of: :subsidy_budgets
    belongs_to :fee_component,
               class_name: "Commercial::FeeComponent",
               inverse_of: :subsidy_budgets

    before_validation :normalize_currency

    validates :fee_component, presence: true
    validates :currency,
              presence: true,
              format: { with: /\A[A-Z]{3}\z/ }
    validates :limit_minor,
              numericality: { only_integer: true, greater_than: 0 }
    validates :reserved_minor, :consumed_minor, :lock_version,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :fee_component_id,
              uniqueness: {
                scope: %i[assignment_id currency],
                conditions: -> { where.not(assignment_id: nil) }
              },
              if: -> { assignment_id.present? }
    validates :fee_component_id,
              uniqueness: {
                scope: %i[program_id currency],
                conditions: -> { where.not(program_id: nil) }
              },
              if: -> { program_id.present? }

    validate :exactly_one_owner
    validate :owner_component_alignment
    validate :platform_subsidy_component
    validate :component_currency_support
    validate :counter_total_within_limit

    scope :for_assignment, ->(assignment_id) { where(assignment_id:) }
    scope :for_program, ->(program_id) { where(program_id:) }
    scope :for_component, ->(fee_component_id) { where(fee_component_id:) }
    scope :in_currency, ->(currency) { where(currency: currency.to_s.strip.upcase) }

    def remaining_minor
      return if [ limit_minor, reserved_minor, consumed_minor ].any?(&:blank?)

      limit_minor - reserved_minor - consumed_minor
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id assignment_id program_id fee_component_id currency limit_minor reserved_minor
        consumed_minor lock_version created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[assignment program fee_component]
    end

    private

    def normalize_currency
      self.currency = currency.to_s.strip.upcase.presence
    end

    def exactly_one_owner
      return if [ assignment_id, program_id ].count(&:present?) == 1

      errors.add(:base, I18n.t("commercial.subsidies.errors.owner_exclusive"))
    end

    def owner_component_alignment
      return if fee_component_id.blank? || (assignment_id.blank? && program_id.blank?)

      component_version_id = fee_component_version_id
      return if component_version_id.blank?

      aligned = if assignment_id.present?
        assignment_fee_schedule_version_id == component_version_id
      else
        program_fee_schedule_id == component_fee_schedule_id(component_version_id)
      end
      return if aligned

      errors.add(:fee_component, I18n.t("commercial.subsidies.errors.owner_component_mismatch"))
    end

    def platform_subsidy_component
      component_type = if association(:fee_component).loaded?
        fee_component&.component_type
      else
        Commercial::FeeComponent.where(id: fee_component_id).pick(:component_type)
      end
      return if component_type.blank? || component_type == "platform_subsidy"

      errors.add(:fee_component, I18n.t("commercial.subsidies.errors.platform_subsidy_required"))
    end

    def component_currency_support
      return if fee_component_id.blank? || currency.blank?

      scoped_currency = fee_component_scope_currency
      if scoped_currency.present? && scoped_currency != currency
        errors.add(:currency, I18n.t("commercial.subsidies.errors.currency_mismatch"))
        return
      end

      amounts = Commercial::FeeAmount.where(fee_component_id:).select(:currency)
      return unless amounts.exists?
      return if amounts.exists?(currency:)

      errors.add(:currency, I18n.t("commercial.subsidies.errors.currency_mismatch"))
    end

    def counter_total_within_limit
      return if [ limit_minor, reserved_minor, consumed_minor ].any?(&:blank?)
      return if reserved_minor + consumed_minor <= limit_minor

      errors.add(:base, I18n.t("commercial.subsidies.errors.counter_limit"))
    end

    def fee_component_version_id
      return fee_component&.fee_schedule_version_id if association(:fee_component).loaded?

      Commercial::FeeComponent.where(id: fee_component_id).pick(:fee_schedule_version_id)
    end

    def assignment_fee_schedule_version_id
      return assignment&.fee_schedule_version_id if association(:assignment).loaded?

      Commercial::Assignment.where(id: assignment_id).pick(:fee_schedule_version_id)
    end

    def program_fee_schedule_id
      return program&.fee_schedule_id if association(:program).loaded?

      Commercial::Program.where(id: program_id).pick(:fee_schedule_id)
    end

    def component_fee_schedule_id(version_id)
      Commercial::FeeScheduleVersion.where(id: version_id).pick(:fee_schedule_id)
    end

    def fee_component_scope_currency
      return fee_component&.currency if association(:fee_component).loaded?

      Commercial::FeeComponent.where(id: fee_component_id).pick(:currency)
    end
  end
end
