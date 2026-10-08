# frozen_string_literal: true

module Ticketing
  # Durable event-owned authorization to pair one scanner for an invited phone.
  # Link material is encrypted only for delivery; lookup values are keyed digests.
  class ScannerInvitation < Ticketing::ApplicationRecord
    self.table_name = "ticketing_scanner_invitations"

    include Core::AuditableModel

    STATUSES = %w[pending paired pairing_reset expired revoked].freeze
    LIVE_STATUSES = %w[pending paired pairing_reset].freeze
    PAIRABLE_STATUSES = %w[pending pairing_reset].freeze
    DELIVERY_STATUSES = %w[queued accepted delivered failed unknown].freeze
    ZONE_MODES = %w[all_current_zones selected_zones].freeze
    PAIRING_METHODS = %w[sms_link organizer_qr short_code].freeze

    belongs_to :event, class_name: "Events::Event"
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :created_by, class_name: "Core::User"
    belongs_to :paired_user, class_name: "Core::User", optional: true
    belongs_to :event_staff_assignment, class_name: "Events::EventStaffAssignment", optional: true
    belongs_to :scanner_device, class_name: "Ticketing::ScannerDevice", optional: true
    belongs_to :scanner_device_assignment, class_name: "Ticketing::ScannerDeviceAssignment", optional: true

    has_many :scanner_sessions,
             class_name: "Ticketing::ScannerSession",
             dependent: :restrict_with_exception,
             inverse_of: :scanner_invitation

    encrypts :phone_ciphertext, :token_ciphertext, :pairing_code_ciphertext

    validates :phone_ciphertext, presence: true
    validates :phone_digest,
              presence: true,
              format: { with: /\A[0-9a-f]{64}\z/ },
              uniqueness: {
                scope: :event_id,
                conditions: -> { where(status: LIVE_STATUSES) }
              },
              if: -> { status.in?(LIVE_STATUSES) }
    validates :token_digest, :create_idempotency_key_digest, :create_request_digest,
              presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :token_ciphertext, :pairing_code_ciphertext,
              presence: true, if: -> { status.in?(PAIRABLE_STATUSES) }
    validates :pairing_code_digest,
              presence: true,
              format: { with: /\A[0-9a-f]{64}\z/ },
              uniqueness: { conditions: -> { where(status: PAIRABLE_STATUSES) } },
              if: -> { status.in?(PAIRABLE_STATUSES) }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :delivery_status, presence: true, inclusion: { in: DELIVERY_STATUSES }
    validates :zone_mode, presence: true, inclusion: { in: ZONE_MODES }
    validates :pairing_method, inclusion: { in: PAIRING_METHODS }, allow_nil: true
    validates :delivery_revision, numericality: { only_integer: true, greater_than: 0 }
    validates :delivery_attempts,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :organizer_note, length: { maximum: 500 }, allow_blank: true
    validates :display_label, length: { maximum: 120 }, allow_blank: true
    validate :phone_is_valid
    validate :zone_ids_are_an_array
    validate :access_window_is_finite_and_ordered
    validate :paired_state_is_complete

    scope :live, -> { where(status: LIVE_STATUSES) }
    scope :pairable, -> { where(status: PAIRABLE_STATUSES) }

    def phone
      phone_ciphertext
    end

    def phone=(value)
      normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(value)
      self.phone_ciphertext = normalized.present? ? "+#{normalized}" : nil
    end

    def token
      token_ciphertext
    end

    def token=(value)
      self.token_ciphertext = value
    end

    def pairing_code
      pairing_code_ciphertext
    end

    def pairing_code=(value)
      self.pairing_code_ciphertext = value
    end

    def note
      organizer_note
    end

    def note=(value)
      self.organizer_note = value.to_s.presence
    end

    def masked_phone
      self.class.mask_phone(phone)
    end

    def effective_status(at = Time.current)
      return "expired" if status.in?(PAIRABLE_STATUSES) && expires_at <= at

      status
    end

    def pairable_at?(at = Time.current)
      status.in?(PAIRABLE_STATUSES) && expires_at.present? && expires_at > at
    end

    def self.phone_digest_for(event_id:, phone:)
      normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(phone)
      return if normalized.blank?

      Core::KeyedDigest.digest(namespace: "ticketing/scanner-invitation-phone/#{event_id}", value: normalized)
    end

    def self.token_digest_for(token:)
      Core::KeyedDigest.digest(namespace: "ticketing/scanner-invitation-token", value: token.to_s)
    end

    def self.pairing_code_digest_for(code:)
      Core::KeyedDigest.digest(namespace: "ticketing/scanner-invitation-code", value: code.to_s)
    end

    def self.mask_phone(value)
      normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(value)
      return if normalized.blank?

      "+#{normalized.first(5)}***#{normalized.last(2)}"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_id organization_id created_by_id paired_user_id event_staff_assignment_id
        scanner_device_id scanner_device_assignment_id phone_digest display_label status delivery_status
        delivery_revision starts_at ends_at expires_at pairing_code_expires_at paired_at revoked_at
        expired_at last_delivery_at created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event organization created_by paired_user event_staff_assignment scanner_device scanner_device_assignment]
    end

    private

    def phone_is_valid
      return if Core::PhoneIdentity::ResolveOrCreate.normalize(phone).present?

      errors.add(:phone_ciphertext, :invalid)
    end

    def zone_ids_are_an_array
      return if selected_zone_ids.is_a?(Array)

      errors.add(:selected_zone_ids, :invalid)
    end

    def access_window_is_finite_and_ordered
      return if starts_at.present? && ends_at.present? && expires_at.present? &&
        pairing_code_expires_at.present? && starts_at < ends_at && expires_at <= ends_at &&
        pairing_code_expires_at <= expires_at

      errors.add(:ends_at, :invalid)
    end

    def paired_state_is_complete
      return unless status == "paired"
      return if paired_at.present? && paired_user_id.present? && event_staff_assignment_id.present? &&
        scanner_device_id.present? && scanner_device_assignment_id.present? && pairing_method.present?

      errors.add(:status, :invalid)
    end
  end
end
