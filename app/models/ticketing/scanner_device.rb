# frozen_string_literal: true

module Ticketing
  # A reusable physical scanner or app installation registered to one organization.
  # Scanner authorization belongs to event-scoped ScannerSessions, not the device.
  class ScannerDevice < Ticketing::ApplicationRecord
    self.table_name = "ticketing_scanner_devices"

    include Core::AuditableModel

    STATUSES = %w[active suspended revoked].freeze

    belongs_to :organization, class_name: "Organizations::Organization"

    has_many :assignments,
             class_name: "Ticketing::ScannerDeviceAssignment",
             dependent: :restrict_with_exception,
             inverse_of: :scanner_device

    validates :device_identifier, presence: true, uniqueness: true
    validates :status, presence: true, inclusion: { in: STATUSES }

    scope :active, -> { where(status: "active") }

    def active?
      status == "active"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id device_identifier name status last_seen_at revoked_at
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization assignments]
    end
  end
end
