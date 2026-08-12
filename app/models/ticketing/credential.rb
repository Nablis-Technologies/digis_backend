# frozen_string_literal: true

module Ticketing
  # A signed bearer QR/PNR credential. The credential UUID is never reused;
  # generation replacement and revocation preserve the offline scanner's
  # ability to reject stale or individually revoked credentials.
  class Credential < Ticketing::ApplicationRecord
    self.table_name = "ticketing_credentials"
    self.inheritance_column = nil

    TYPES = %w[package individual].freeze
    STATUSES = %w[pending_claim pending_requirements active revoked].freeze

    belongs_to :ticket, class_name: "Ticketing::Ticket"
    belongs_to :credential_generation,
               class_name: "Ticketing::CredentialGeneration"
    belongs_to :admission_slot,
               class_name: "Ticketing::AdmissionSlot",
               optional: true
    belongs_to :event, class_name: "Events::Event"
    belongs_to :holder_user, class_name: "Core::User", optional: true

    has_one :credential_claim,
            class_name: "Ticketing::CredentialClaim",
            dependent: :restrict_with_exception
    has_one :credential_revocation,
            class_name: "Ticketing::CredentialRevocation",
            dependent: :restrict_with_exception
    has_one :attendee_index_entry,
            class_name: "Ticketing::AttendeeIndexEntry",
            dependent: :restrict_with_exception

    encrypts :holder_name

    validates :type, presence: true, inclusion: { in: TYPES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :entry_limit, numericality: { only_integer: true, greater_than: 0 }
    validates :lookup_code, length: { maximum: 8 }, allow_blank: true
    validate :slot_positions_are_positive_and_unique
    validate :type_matches_generation
    validate :admission_slot_matches_type
    validate :activation_state_matches
    validate :event_matches_ticket

    scope :active, -> { where(status: "active") }

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id ticket_id credential_generation_id admission_slot_id event_id type holder_user_id
        status entry_limit lookup_code issued_at revoked_at revocation_reason created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket credential_generation admission_slot event holder_user credential_claim
         credential_revocation attendee_index_entry]
    end

    private

    def slot_positions_are_positive_and_unique
      positions = Array(slot_positions).compact
      errors.add(:slot_positions, :blank) if positions.empty?
      errors.add(:slot_positions, :invalid) unless positions.all? { |position| position.to_i.positive? }
      errors.add(:slot_positions, :invalid) unless positions.uniq.length == positions.length
      errors.add(:entry_limit, :invalid) unless entry_limit.to_i == positions.length
    end

    def type_matches_generation
      return if credential_generation.blank?

      expected_type = credential_generation.mode == "group" ? "package" : "individual"
      errors.add(:type, :invalid) unless type == expected_type
      if credential_generation.status == "revoked" && status != "revoked"
        errors.add(:status, :invalid)
      end
    end

    def admission_slot_matches_type
      if type == "package" && admission_slot_id.present?
        errors.add(:admission_slot, :invalid)
      elsif type == "individual"
        errors.add(:admission_slot, :blank) if admission_slot_id.blank?
        errors.add(:entry_limit, :invalid) unless entry_limit.to_i == 1
      end

      return if admission_slot.blank? || ticket.blank?
      return if admission_slot.ticket_id == ticket_id && slot_positions == [ admission_slot.position ]

      errors.add(:admission_slot, :invalid)
    end

    def activation_state_matches
      if %w[pending_claim pending_requirements].include?(status)
        errors.add(:qr_token, :invalid) if qr_token.present?
        errors.add(:lookup_code, :invalid) if lookup_code.present?
        errors.add(:issued_at, :invalid) if issued_at.present?
      elsif status == "active"
        errors.add(:qr_token, :blank) if qr_token.blank?
        errors.add(:lookup_code, :blank) if lookup_code.blank?
        errors.add(:issued_at, :blank) if issued_at.blank?
      end

      if status == "revoked"
        errors.add(:revoked_at, :blank) if revoked_at.blank?
      elsif revoked_at.present?
        errors.add(:revoked_at, :invalid)
      end
    end

    def event_matches_ticket
      return if ticket.blank? || event_id == ticket.event_id

      errors.add(:event, :invalid)
    end
  end
end
