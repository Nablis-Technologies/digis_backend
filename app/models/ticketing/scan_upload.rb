# frozen_string_literal: true

module Ticketing
  # A retry-safe server receipt for one offline scanner batch. Individual
  # check-in rows remain independently idempotent through client_scan_id.
  class ScanUpload < Ticketing::ApplicationRecord
    self.table_name = "ticketing_scan_uploads"

    belongs_to :scanner_device_assignment,
               class_name: "Ticketing::ScannerDeviceAssignment",
               inverse_of: :scan_uploads

    has_many :checkin_logs,
             class_name: "Ticketing::CheckinLog",
             dependent: :restrict_with_exception,
             inverse_of: :scan_upload

    validates :client_upload_id,
              presence: true,
              uniqueness: { scope: :scanner_device_assignment_id }
    validates :received_at, presence: true
    validate :completed_after_received

    def self.ransackable_attributes(_auth_object = nil)
      %w[id scanner_device_assignment_id client_upload_id received_at completed_at
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[scanner_device_assignment checkin_logs]
    end

    private

    def completed_after_received
      return if completed_at.blank? || received_at.blank? || completed_at >= received_at

      errors.add(:completed_at, :invalid)
    end
  end
end
