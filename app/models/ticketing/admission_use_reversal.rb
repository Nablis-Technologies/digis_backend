# frozen_string_literal: true

module Ticketing
  # Append-only manager correction for a successful admission-use group.
  # Reversing a group restores eligibility without mutating the original scan
  # or use rows and without reusing their historical usage numbers.
  class AdmissionUseReversal < Ticketing::ApplicationRecord
    self.table_name = "ticketing_admission_use_reversals"

    belongs_to :event, class_name: "Events::Event"
    belongs_to :admission_use,
               class_name: "Ticketing::AdmissionUse",
               inverse_of: :reversal
    belongs_to :checkin_log, class_name: "Ticketing::CheckinLog"
    belongs_to :reversed_by, class_name: "Core::User"

    validates :reason_code, presence: true
    validates :reversal_version, numericality: { only_integer: true, greater_than: 0 }
    validates :reversed_at, presence: true
    validates :admission_use_id, uniqueness: true

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id admission_use_id checkin_log_id reversal_group_id reversed_by_id reason_code note
         reversal_version reversed_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event admission_use checkin_log reversed_by]
    end
  end
end
