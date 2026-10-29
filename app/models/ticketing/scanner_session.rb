# frozen_string_literal: true

module Ticketing
  # Opaque event-scoped Bearer session. The digest is the only persisted
  # authenticator; event, operator, device, and zones derive from its assignment.
  class ScannerSession < Ticketing::ApplicationRecord
    self.table_name = "ticketing_scanner_sessions"

    belongs_to :scanner_invitation,
               class_name: "Ticketing::ScannerInvitation",
               inverse_of: :scanner_sessions
    belongs_to :scanner_device_assignment,
               class_name: "Ticketing::ScannerDeviceAssignment",
               inverse_of: :scanner_sessions

    validates :token_digest,
              presence: true,
              format: { with: /\A[0-9a-f]{64}\z/ },
              uniqueness: true
    validates :idempotency_key_digest, :request_digest,
              presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :expires_at, presence: true
    validate :assignment_matches_invitation

    scope :unrevoked, -> { where(revoked_at: nil) }

    def self.token_digest_for(token:)
      Core::KeyedDigest.digest(namespace: "ticketing/scanner-session-token", value: token.to_s)
    end

    def active_at?(at = Time.current)
      return false if revoked_at.present? || expires_at <= at
      return false unless scanner_invitation.status == "paired"
      return false unless scanner_device_assignment.active_now?(at)
      return false unless scanner_device_assignment.event_staff_assignment.active?
      return false unless scanner_device_assignment.scanner_device.active?

      !scanner_device_assignment.event.status.in?(%w[cancelled completed])
    end

    private

    def assignment_matches_invitation
      return if scanner_invitation.blank? || scanner_device_assignment.blank?
      return if scanner_invitation.event_id == scanner_device_assignment.event_id &&
        scanner_invitation.event_staff_assignment_id == scanner_device_assignment.event_staff_assignment_id &&
        scanner_invitation.scanner_device_assignment_id == scanner_device_assignment_id

      errors.add(:scanner_device_assignment, :invalid)
    end
  end
end
