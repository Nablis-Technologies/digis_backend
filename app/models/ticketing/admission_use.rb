# frozen_string_literal: true

module Ticketing
  # Historical consumption of one admission slot for one product access.
  # Reversals append separate rows; this record is never edited or deleted.
  class AdmissionUse < Ticketing::ApplicationRecord
    self.table_name = "ticketing_admission_uses"

    belongs_to :admission_slot, class_name: "Ticketing::AdmissionSlot"
    belongs_to :product_access, class_name: "Catalog::ProductAccess"
    belongs_to :credential, class_name: "Ticketing::Credential"
    belongs_to :checkin_log,
               class_name: "Ticketing::CheckinLog",
               inverse_of: :admission_uses

    has_one :reversal,
            class_name: "Ticketing::AdmissionUseReversal",
            dependent: :restrict_with_exception,
            inverse_of: :admission_use

    validates :usage_number, numericality: { only_integer: true, greater_than: 0 }
    validates :used_at, presence: true
    validates :usage_number, uniqueness: { scope: %i[admission_slot_id product_access_id] }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id admission_slot_id product_access_id credential_id checkin_log_id usage_number used_at
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[admission_slot product_access credential checkin_log reversal]
    end
  end
end
