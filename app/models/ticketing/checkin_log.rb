# frozen_string_literal: true

module Ticketing
  # Immutable audit record for one online or offline admission attempt. A
  # successful row may produce admission uses; corrections append a separate
  # manager override row instead of changing this historical record.
  class CheckinLog < Ticketing::ApplicationRecord
    self.table_name = "ticketing_checkin_logs"

    RESULTS = %w[
      success duplicate invalid version_mismatch revoked wrong_date wrong_channel wrong_zone
      identity_mismatch
    ].freeze
    LOOKUP_METHODS = %w[qr code phone name].freeze
    IDENTITY_RESULTS = %w[not_required matched mismatch].freeze

    belongs_to :ticket, class_name: "Ticketing::Ticket"
    belongs_to :credential, class_name: "Ticketing::Credential"
    belongs_to :product_access, class_name: "Catalog::ProductAccess"
    belongs_to :event_date, class_name: "Events::EventDate"
    belongs_to :access_zone, class_name: "Events::AccessZone", optional: true
    belongs_to :scanner_device_assignment,
               class_name: "Ticketing::ScannerDeviceAssignment",
               optional: true,
               inverse_of: :checkin_logs
    belongs_to :scan_upload,
               class_name: "Ticketing::ScanUpload",
               optional: true,
               inverse_of: :checkin_logs
    belongs_to :identity_checked_by, class_name: "Core::User", optional: true
    belongs_to :overrides_checkin_log,
               class_name: "Ticketing::CheckinLog",
               optional: true,
               inverse_of: :identity_override
    belongs_to :identity_override_by, class_name: "Core::User", optional: true

    has_many :admission_uses,
             class_name: "Ticketing::AdmissionUse",
             dependent: :restrict_with_exception,
             inverse_of: :checkin_log
    has_one :identity_override,
            class_name: "Ticketing::CheckinLog",
            foreign_key: :overrides_checkin_log_id,
            dependent: :restrict_with_exception,
            inverse_of: :overrides_checkin_log

    validates :credential_version, numericality: { only_integer: true, greater_than: 0 }
    validates :result, presence: true, inclusion: { in: RESULTS }
    validates :lookup_via, presence: true, inclusion: { in: LOOKUP_METHODS }
    validates :identity_check_result, presence: true, inclusion: { in: IDENTITY_RESULTS }
    validates :client_scan_id, presence: true, uniqueness: true
    validates :scanned_at, :received_at, presence: true
    validate :manual_lookup_reason
    validate :identity_check_shape
    validate :identity_override_shape

    def self.ransackable_attributes(_auth_object = nil)
      %w[id ticket_id credential_id credential_version product_access_id event_date_id access_zone_id
         scanner_device_assignment_id scan_upload_id client_scan_id result lookup_via reason_code
         identity_check_result identity_checked_by_id overrides_checkin_log_id identity_override_by_id
         identity_override_reason identity_overridden_at scanned_at received_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket credential product_access event_date access_zone scanner_device_assignment scan_upload
         identity_checked_by overrides_checkin_log identity_override_by admission_uses identity_override]
    end

    # Returns the allowlisted result persisted inside an upload snapshot. It
    # deliberately excludes holder, consent, financial, and raw credential
    # data; loaded uses are reused to keep batch reconciliation bounded.
    def serialized_result
      uses = if association(:admission_uses).loaded?
        association(:admission_uses).target
      else
        admission_uses.to_a
      end

      {
        "client_scan_id" => client_scan_id.to_s,
        "server_checkin_id" => id.to_s,
        "result" => result,
        "credential_id" => credential_id.to_s,
        "credential_version" => credential_version,
        "product_access_id" => product_access_id.to_s,
        "event_date_id" => event_date_id.to_s,
        "server_use_ids" => uses.sort_by { |use| [ use.admission_slot_id.to_s, use.usage_number ] }.map do |use|
          use.id.to_s
        end,
        "admission_uses" => uses.sort_by { |use| [ use.admission_slot_id.to_s, use.usage_number ] }.map do |use|
          {
            "id" => use.id.to_s,
            "admission_slot_id" => use.admission_slot_id.to_s,
            "usage_number" => use.usage_number
          }
        end
      }
    end

    private

    def manual_lookup_reason
      return if lookup_via.blank? || lookup_via == "qr" || reason_code.present?

      errors.add(:reason_code, :blank)
    end

    def identity_check_shape
      if identity_check_result == "not_required"
        errors.add(:identity_checked_by, :invalid) if identity_checked_by_id.present?
      elsif identity_checked_by_id.blank?
        errors.add(:identity_checked_by, :blank)
      end
    end

    def identity_override_shape
      override_fields = [
        identity_override_by_id,
        identity_override_reason,
        identity_overridden_at,
        overrides_checkin_log_id
      ]
      return if override_fields.all?(&:blank?)

      errors.add(:identity_override_by, :blank) if identity_override_by_id.blank?
      errors.add(:identity_override_reason, :blank) if identity_override_reason.blank?
      errors.add(:identity_overridden_at, :blank) if identity_overridden_at.blank?
      errors.add(:overrides_checkin_log, :blank) if overrides_checkin_log_id.blank?
      errors.add(:result, :invalid) unless result == "success"
      errors.add(:identity_check_result, :invalid) unless identity_check_result == "mismatch"
      errors.add(:scan_upload, :invalid) if scan_upload_id.present? || scan_upload.present?
    end
  end
end
