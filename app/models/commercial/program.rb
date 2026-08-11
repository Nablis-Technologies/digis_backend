# frozen_string_literal: true

module Commercial
  # Reusable commercial eligibility backed by one immutable program fee schedule.
  class Program < Commercial::ApplicationRecord
    self.table_name = "commercial_programs"

    PROGRAM_TYPES = %w[first_monetized_event charity partnership volume].freeze
    ENROLLMENT_MODES = %w[automatic manual].freeze
    STRATEGY_REGISTRY = PROGRAM_TYPES.index_with(&:to_sym).freeze

    belongs_to :fee_schedule,
               class_name: "Commercial::FeeSchedule",
               inverse_of: :program
    has_many :assignments,
             class_name: "Commercial::Assignment",
             inverse_of: :program,
             dependent: :restrict_with_exception
    has_many :entitlements,
             class_name: "Commercial::ProgramEntitlement",
             inverse_of: :program,
             dependent: :restrict_with_exception

    validates :fee_schedule, presence: true
    validates :program_type, presence: true, inclusion: { in: PROGRAM_TYPES }
    validates :enrollment_mode, presence: true, inclusion: { in: ENROLLMENT_MODES }
    validates :active, inclusion: { in: [ true, false ] }
    validates :per_organization_use_limit,
              numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validate :fee_schedule_must_be_program
    validate :effective_interval

    scope :active_at, lambda { |at|
      where(active: true)
        .where("starts_at IS NULL OR starts_at <= ?", at)
        .where("ends_at IS NULL OR ends_at > ?", at)
    }

    def strategy_key
      STRATEGY_REGISTRY.fetch(program_type)
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id fee_schedule_id program_type enrollment_mode starts_at ends_at
        per_organization_use_limit active created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[fee_schedule assignments entitlements]
    end

    private

    def fee_schedule_must_be_program
      return if fee_schedule.blank? || fee_schedule.schedule_type == "program"

      errors.add(:fee_schedule, I18n.t("commercial.programs.errors.program_schedule_required"))
    end

    def effective_interval
      return if starts_at.blank? || ends_at.blank? || ends_at > starts_at

      errors.add(:ends_at, I18n.t("commercial.programs.errors.effective_interval"))
    end
  end
end
