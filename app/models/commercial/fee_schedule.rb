# frozen_string_literal: true

module Commercial
  class FeeSchedule < Commercial::ApplicationRecord
    self.table_name = "commercial_fee_schedules"

    SCHEDULE_TYPES = %w[platform_default program custom].freeze

    belongs_to :created_by, class_name: "Core::User", foreign_key: :created_by_id
    has_many :fee_schedule_versions,
             class_name: "Commercial::FeeScheduleVersion",
             inverse_of: :fee_schedule,
             dependent: :restrict_with_exception
    has_one :program,
            class_name: "Commercial::Program",
            inverse_of: :fee_schedule,
            dependent: :restrict_with_exception

    before_validation :normalize_code

    validates :name, presence: true
    validates :code, presence: true, uniqueness: true,
              format: { with: /\A[a-z0-9]+(?:_[a-z0-9]+)*\z/ }
    validates :schedule_type, presence: true, inclusion: { in: SCHEDULE_TYPES }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id name code schedule_type created_by_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[created_by fee_schedule_versions program]
    end

    private

    def normalize_code
      self.code = code.to_s.strip.downcase.presence
    end
  end
end
