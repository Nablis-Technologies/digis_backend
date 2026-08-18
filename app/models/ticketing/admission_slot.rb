# frozen_string_literal: true

module Ticketing
  # A durable admission position inside a package. Slot identity survives
  # credential replacement so delegation and entry history never move access
  # between people by accident.
  class AdmissionSlot < Ticketing::ApplicationRecord
    self.table_name = "ticketing_admission_slots"

    STATUSES = %w[unassigned pending_claim claimed].freeze

    belongs_to :ticket, class_name: "Ticketing::Ticket"
    belongs_to :assigned_user, class_name: "Core::User", optional: true

    has_many :credentials,
             class_name: "Ticketing::Credential",
             dependent: :restrict_with_exception

    validates :position, numericality: { only_integer: true, greater_than: 0 }
    validates :assignment_status, presence: true, inclusion: { in: STATUSES }
    validate :claimed_state_matches

    def self.ransackable_attributes(_auth_object = nil)
      %w[id ticket_id position assigned_user_id assignment_status claimed_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket assigned_user credentials]
    end

    private

    def claimed_state_matches
      if assignment_status == "claimed"
        errors.add(:assigned_user, :blank) if assigned_user_id.blank?
        errors.add(:claimed_at, :blank) if claimed_at.blank?
      elsif claimed_at.present?
        errors.add(:claimed_at, :invalid)
      end
    end
  end
end
