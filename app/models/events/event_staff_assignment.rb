# frozen_string_literal: true

module Events
  class EventStaffAssignment < Events::ApplicationRecord
    self.table_name = "events_event_staff_assignments"
    self.inheritance_column = nil

    include Core::AuditableModel

    ROLES = %w[manager staff scanner contractor].freeze
    GENERAL_ROLES = %w[manager staff contractor].freeze
    STATUSES = %w[active suspended revoked expired].freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :event_staff_assignments
    belongs_to :user, class_name: "Core::User"
    belongs_to :organization, class_name: "Organizations::Organization"

    validates :role, presence: true, inclusion: { in: ROLES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :user_id, uniqueness: { scope: %i[event_id role],
                                       message: ->(record, data) { I18n.t("events.staff_assignment.errors.duplicate_assignment") } }
    validate :one_active_general_role_per_event_user

    scope :active, -> { where(status: "active") }
    scope :managers, -> { where(role: "manager", status: "active") }

    def active?
      status == "active"
    end

    def self.active_general_role_conflict?(event_id:, user_id:, except_id: nil)
      scope = where(event_id:, user_id:, status: "active", role: GENERAL_ROLES)
      scope = scope.where.not(id: except_id) if except_id.present?
      scope.exists?
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id role event_id user_id organization_id status created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event user organization]
    end

    private

    def one_active_general_role_per_event_user
      return unless status == "active" && GENERAL_ROLES.include?(role)
      return unless self.class.active_general_role_conflict?(event_id:, user_id:, except_id: id)

      errors.add(:role, I18n.t("events.staff_assignment.errors.staff_assignment_role_change_required"))
    end
  end
end
