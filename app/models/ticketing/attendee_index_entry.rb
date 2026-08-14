# frozen_string_literal: true

module Ticketing
  # Persisted attendee lookup projection for PNR, phone-hash, and offline index
  # delta sync. It contains only scanner-safe access metadata; registration
  # answers, consent evidence, prices, and financial history stay server-side.
  class AttendeeIndexEntry < Ticketing::ApplicationRecord
    self.table_name = "ticketing_attendee_index_entries"
    self.inheritance_column = nil

    MODES = %w[group delegated].freeze
    ENTRY_VALIDATION_MODES = %w[qr qr_and_id].freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :attendee_index_entries
    belongs_to :credential, class_name: "Ticketing::Credential"
    belongs_to :ticket, class_name: "Ticketing::Ticket"

    encrypts :holder_name

    validates :lookup_code, presence: true, length: { maximum: 8 }
    validates :credential_mode, presence: true, inclusion: { in: MODES }
    validates :entry_validation_mode, presence: true, inclusion: { in: ENTRY_VALIDATION_MODES }
    validates :generation_version, :entry_limit,
              numericality: { only_integer: true, greater_than: 0 }
    validates :index_version,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :slot_positions_are_positive_and_unique

    scope :active, -> { where(removed: false) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_id lookup_code phone_hash owner_phone_hash credential_id ticket_id
        credential_mode generation_version entry_limit ticket_type ticket_type_label
        entry_validation_mode index_version removed created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event credential ticket]
    end

    private

    def slot_positions_are_positive_and_unique
      positions = Array(slot_positions).compact
      errors.add(:slot_positions, :blank) if positions.empty?
      errors.add(:slot_positions, :invalid) unless positions.all? { |position| position.to_i.positive? }
      errors.add(:slot_positions, :invalid) unless positions.uniq.length == positions.length
      errors.add(:entry_limit, :invalid) unless entry_limit.to_i == positions.length
    end
  end
end
