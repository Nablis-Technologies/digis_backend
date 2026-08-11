# frozen_string_literal: true

module Commercial
  class FeeSchedule < Commercial::ApplicationRecord
    self.table_name = "commercial_fee_schedules"

    validates :name, presence: true

    def self.ransackable_attributes(_auth_object = nil)
      %w[id name created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[]
    end
  end
end
