# frozen_string_literal: true

require "active_support/security_utils"

module Ticketing
  # A reusable physical scanner or app installation registered to one organization.
  # Authentication material is represented only by its digest; plaintext device
  # tokens never belong in this model or its persistence layer.
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
    validates :token_digest,
              presence: true,
              uniqueness: true,
              format: { with: /\A[0-9a-f]{64}\z/ }
    validates :status, presence: true, inclusion: { in: STATUSES }

    scope :active, -> { where(status: "active") }

    def self.token_digest_for(token:)
      Core::KeyedDigest.digest(namespace: "ticketing-scanner-device", value: token)
    end

    def self.constant_time_digest_match?(expected, actual)
      expected = expected.to_s
      actual = actual.to_s
      return false unless expected.bytesize == actual.bytesize

      ActiveSupport::SecurityUtils.secure_compare(expected, actual)
    end

    def active?
      status == "active"
    end

    def token_matches?(token)
      self.class.constant_time_digest_match?(token_digest, self.class.token_digest_for(token:))
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id device_identifier name token_digest status last_seen_at revoked_at
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization assignments]
    end
  end
end
