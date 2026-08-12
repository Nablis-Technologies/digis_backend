# frozen_string_literal: true

module Ticketing
  # Explicitly scopes an event scanner assignment to one access zone.
  # Cross-event mappings are rejected by the database trigger because the
  # assignment and zone must remain in the same event boundary.
  class ScannerAssignmentZone < Ticketing::ApplicationRecord
    self.table_name = "ticketing_scanner_assignment_zones"

    belongs_to :scanner_device_assignment,
               class_name: "Ticketing::ScannerDeviceAssignment",
               inverse_of: :assignment_zones
    belongs_to :access_zone, class_name: "Events::AccessZone"

    validates :access_zone_id,
              uniqueness: { scope: :scanner_device_assignment_id }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id scanner_device_assignment_id access_zone_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[scanner_device_assignment access_zone]
    end
  end
end
