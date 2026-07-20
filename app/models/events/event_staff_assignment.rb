# frozen_string_literal: true

module Events
  class EventStaffAssignment < Events::ApplicationRecord
    self.table_name = "events_event_staff_assignments"
    self.inheritance_column = nil

    include Core::AuditableModel

    ROLES = %w[manager staff scanner contractor].freeze
    STATUSES = %w[active suspended revoked expired].freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :event_staff_assignments
    belongs_to :user, class_name: "Core::User"
    belongs_to :organization, class_name: "Organizations::Organization"

    validates :role, presence: true, inclusion: { in: ROLES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :user_id, uniqueness: { scope: %i[event_id role],
                                       message: :duplicate_staff_assignment }

    scope :active, -> { where(status: "active") }
    scope :managers, -> { where(role: "manager", status: "active") }

    def active?
      status == "active"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id role event_id user_id organization_id status created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event user organization]
    end
  end
end
