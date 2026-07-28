# frozen_string_literal: true

module Ticketing
  # Named guest-list invitations. Contact details are encrypted at rest and a
  # searchable contact digest plus a unique link-token digest are stored.
  # Raw tokens are never persisted.
  class Invitation < Ticketing::ApplicationRecord
    self.table_name = "ticketing_invitations"

    STATUSES = %w[pending accepted revoked expired].freeze

    belongs_to :ticket_type, class_name: "Ticketing::TicketType", inverse_of: :invitations
    belongs_to :invited_user,
               class_name: "Core::User",
               inverse_of: :invitations,
               optional: true
    belongs_to :created_by,
               class_name: "Core::User",
               inverse_of: :created_invitations

    # Contacts are encrypted at rest in the `*_ciphertext` columns. We encrypt
    # those columns directly and expose `email`/`phone` as plain-text accessors
    # so callers and validations see decrypted values while storage stays
    # ciphertext-only.
    encrypts :email_ciphertext, :phone_ciphertext

    def email
      email_ciphertext
    end

    def email=(value)
      self.email_ciphertext = value
    end

    def phone
      phone_ciphertext
    end

    def phone=(value)
      self.phone_ciphertext = value
    end

    validates :ticket_type, presence: true
    validates :created_by, presence: true
    validates :contact_digest, presence: true
    validates :token_digest, presence: true, uniqueness: true
    validates :allowed_quantity,
              numericality: { only_integer: true, greater_than_or_equal_to: 1 }
    validates :status, presence: true, inclusion: { in: STATUSES }

    # Contact is required (email or phone) so a searchable digest can be built.
    validate :contact_present

    scope :pending, -> { where(status: "pending") }
    scope :claimed, -> { where(status: %w[pending accepted]) }

    def self.contact_digest_for(event_id:, contact:)
      Core::KeyedDigest.digest(namespace: event_id, value: contact.to_s.strip.downcase)
    end

    def self.token_digest_for(event_id:, token:)
      Core::KeyedDigest.digest(namespace: event_id, value: token)
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id ticket_type_id invited_user_id name contact_digest token_digest
        allowed_quantity status expires_at accepted_at created_by_id
        created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket_type invited_user created_by]
    end

    private

    def contact_present
      return if email.present? || phone.present?

      errors.add(:base, I18n.t("ticketing.invitation.errors.contact_required"))
    end
  end
end
