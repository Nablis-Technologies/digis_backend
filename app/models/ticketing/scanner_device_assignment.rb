# frozen_string_literal: true

module Ticketing
  # Grants one registered scanner device a bounded authorization and sync
  # cursor set for one event. The assignment remains historical after it is
  # revoked so uploaded scans retain their original authorization context.
  class ScannerDeviceAssignment < Ticketing::ApplicationRecord
    self.table_name = "ticketing_scanner_device_assignments"

    STATUSES = %w[active suspended revoked expired].freeze

    belongs_to :scanner_device,
               class_name: "Ticketing::ScannerDevice",
               inverse_of: :assignments
    belongs_to :event, class_name: "Events::Event"
    belongs_to :assigned_by, class_name: "Core::User"

    has_many :assignment_zones,
             class_name: "Ticketing::ScannerAssignmentZone",
             dependent: :restrict_with_exception,
             inverse_of: :scanner_device_assignment
    has_many :access_zones, through: :assignment_zones
    has_many :scan_uploads,
             class_name: "Ticketing::ScanUpload",
             dependent: :restrict_with_exception,
             inverse_of: :scanner_device_assignment
    has_many :checkin_logs,
             class_name: "Ticketing::CheckinLog",
             dependent: :restrict_with_exception,
             inverse_of: :scanner_device_assignment

    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :last_revocation_version,
              :last_attendee_index_version,
              :last_schedule_version,
              :last_admission_use_reversal_version,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :ends_after_starts

    scope :active, -> { where(status: "active") }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id scanner_device_id event_id assigned_by_id status starts_at ends_at
         last_revocation_version last_attendee_index_version last_schedule_version
         last_admission_use_reversal_version last_synced_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[scanner_device event assigned_by assignment_zones access_zones scan_uploads checkin_logs]
    end

    private

    def ends_after_starts
      return if starts_at.blank? || ends_at.blank? || ends_at > starts_at

      errors.add(:ends_at, :invalid)
    end
  end
end
