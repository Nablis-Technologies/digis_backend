# frozen_string_literal: true

module Events
  class StaffInvitation < Events::ApplicationRecord
    self.table_name = "events_staff_invitations"

    include Core::AuditableModel

    STATUSES = %w[pending accepted revoked expired].freeze
    ROLES = %w[manager staff contractor].freeze
    CONTACT_TYPES = %w[phone email].freeze
    DELIVERY_STATUSES = %w[queued accepted delivered failed unknown].freeze
    CONTACT_DIGEST_SCOPE = "events_staff_invitations".freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :staff_invitations
    belongs_to :invited_by, class_name: "Core::User"
    belongs_to :accepted_user, class_name: "Core::User", optional: true

    encrypts :contact_ciphertext, :claim_token_ciphertext

    validates :role, presence: true, inclusion: { in: ROLES }
    validates :contact_type, presence: true, inclusion: { in: CONTACT_TYPES }
    validates :contact_digest, :claim_token_digest, :create_idempotency_key_digest, :create_request_digest,
              presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :delivery_status, presence: true, inclusion: { in: DELIVERY_STATUSES }
    validates :delivery_revision, numericality: { only_integer: true, greater_than: 0 }
    validates :delivery_attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :expires_at, presence: true
    validates :contact_digest,
              uniqueness: { scope: :event_id, conditions: -> { where(status: "pending") } },
              if: -> { status == "pending" }
    validates :create_idempotency_key_digest,
              uniqueness: { scope: %i[event_id invited_by_id] }
    validates :claim_idempotency_key_digest,
              format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
    validates :claim_request_digest,
              format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true

    validate :contact_matches_type
    validate :assignment_expiry_is_future
    validate :lifecycle_state_is_consistent
    validate :claim_digest_fields_are_paired

    scope :pending, -> { where(status: "pending") }

    def pending?
      status == "pending"
    end

    def masked_contact
      contact = if contact_type == "phone"
        Core::InvitationContact.parse(phone: contact_ciphertext)
      else
        Core::InvitationContact.parse(email: contact_ciphertext)
      end
      contact.masked_value
    rescue ArgumentError, ActiveRecord::Encryption::Errors::Decryption
      nil
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_id invited_by_id accepted_user_id role contact_type status delivery_status
        delivery_revision delivery_attempts expires_at assignment_expires_at accepted_at revoked_at expired_at
        last_delivery_at created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event invited_by accepted_user]
    end

    def self.claim_token_digest_for(token)
      Core::KeyedDigest.digest(namespace: "events/staff-invitation-token", value: token.to_s)
    end

    private

    def contact_matches_type
      if contact_ciphertext.blank?
        errors.add(:contact_ciphertext, :blank)
        return
      end
      return unless CONTACT_TYPES.include?(contact_type)

      if contact_type == "phone"
        Core::InvitationContact.parse(phone: contact_ciphertext)
      else
        Core::InvitationContact.parse(email: contact_ciphertext)
      end
    rescue ActiveRecord::Encryption::Errors::Decryption
      errors.add(:contact_ciphertext, I18n.t("errors.messages.invalid"))
    rescue ArgumentError
      errors.add(:contact_ciphertext, :invalid)
    end

    def assignment_expiry_is_future
      return if assignment_expires_at.blank? || assignment_expires_at > Time.current

      errors.add(:assignment_expires_at, :invalid)
    end

    def lifecycle_state_is_consistent
      state_valid = case status
      when "pending"
        accepted_user_id.nil? && accepted_at.nil? && revoked_at.nil? && expired_at.nil? &&
          claim_token_ciphertext.present? && claim_idempotency_key_digest.nil? && claim_request_digest.nil?
      when "accepted"
        accepted_user_id.present? && accepted_at.present? && revoked_at.nil? && expired_at.nil? &&
          claim_token_ciphertext.nil? && claim_idempotency_key_digest.present? && claim_request_digest.present?
      when "revoked"
        accepted_user_id.nil? && accepted_at.nil? && revoked_at.present? && expired_at.nil? &&
          claim_token_ciphertext.nil? && claim_idempotency_key_digest.nil? && claim_request_digest.nil?
      when "expired"
        accepted_user_id.nil? && accepted_at.nil? && revoked_at.nil? && expired_at.present? &&
          claim_token_ciphertext.nil? && claim_idempotency_key_digest.nil? && claim_request_digest.nil?
      end
      errors.add(:status, :invalid) unless state_valid
    end

    def claim_digest_fields_are_paired
      return if claim_idempotency_key_digest.present? == claim_request_digest.present?

      errors.add(:claim_request_digest, :invalid)
    end
  end
end
