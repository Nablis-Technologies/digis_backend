# frozen_string_literal: true

module Events
  module AuthorizationResolver
    module_function

    ASSIGNMENT_ROLE_PRIORITY = %w[manager scanner staff contractor].freeze

    def access_granted?(user, event)
      return false if user.nil? || event.nil?
      return true if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN") || user.has_role?("CORE_ADMIN")

      Events::AuthorizationResolver.organization_admin_or_owner?(user, event) ||
        Events::AuthorizationResolver.active_assignment?(user, event)
    end

    def can_manage_catalog?(user, event)
      return false if user.nil? || event.nil?

      manageable_catalog_events(user, Events::Event.where(id: event.id)).exists?
    end

    def manageable_catalog_events(user, scope = Events::Event.all)
      return scope.none if user.nil?
      return scope.all if platform_admin?(user)

      manager_organization_ids = Organizations::Membership
        .where(user:, status: "active", role: %w[owner admin])
        .select(:organization_id)

      co_organizer_event_ids = Events::EventOrganization
        .where(
          organization_id: manager_organization_ids,
          type: "co_organizer",
          status: "active"
        )
        .select(:event_id)

      primary_manager_event_ids = Events::EventStaffAssignment
        .joins(:event)
        .where(user:, role: "manager", status: "active")
        .where("events_event_staff_assignments.organization_id = events_events.organization_id")
        .select(:event_id)

      co_organizer_manager_event_ids = Events::EventStaffAssignment
        .joins(
          "INNER JOIN events_event_organizations catalog_manager_organizations " \
          "ON catalog_manager_organizations.event_id = events_event_staff_assignments.event_id " \
          "AND catalog_manager_organizations.organization_id = events_event_staff_assignments.organization_id"
        )
        .where(user:, role: "manager", status: "active")
        .where(
          catalog_manager_organizations: {
            type: "co_organizer",
            status: "active"
          }
        )
        .select(:event_id)

      scope
        .where(organization_id: manager_organization_ids)
        .or(scope.where(id: co_organizer_event_ids))
        .or(scope.where(id: primary_manager_event_ids))
        .or(scope.where(id: co_organizer_manager_event_ids))
    end

    def role_for(user, event)
      return :none if user.nil? || event.nil?
      return :super_admin if user.has_role?("SUPER_ADMIN")
      return :admin if user.has_role?("ADMIN") || user.has_role?("CORE_ADMIN")

      membership = Organizations::Membership
                   .where(user:, organization: event.organization, status: "active")
                   .where(role: %w[owner admin manager])
                   .first
      return membership.role.to_sym if membership

      assignment_roles = Events::EventStaffAssignment.where(event_id: event.id, user_id: user.id, status: "active")
        .pluck(:role)
      assignment_role = ASSIGNMENT_ROLE_PRIORITY.find { |role| assignment_roles.include?(role) }
      return assignment_role.to_sym if assignment_role

      :none
    end

    def can_assign?(actor, event, target_role)
      return false if actor.nil? || event.nil?

      role = role_for(actor, event)
      return true if %i[super_admin admin owner].include?(role)

      role == :manager && %w[staff scanner].include?(target_role.to_s)
    end

    def organization_admin_or_owner?(user, event)
      Organizations::Membership
        .where(user:, organization: event.organization, status: "active")
        .where(role: %w[owner admin manager])
        .exists?
    end

    def active_assignment?(user, event)
      event.event_staff_assignments
           .where(user:, status: "active")
           .exists?
    end

    # True when the user is a platform admin or an active owner/admin member of
    # the given organization. Used to gate event creation.
    def organization_admin?(user, organization)
      return true if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
      return false if user.nil? || organization.nil?

      Organizations::Membership
        .where(user:, organization:, status: "active")
        .where(role: %w[owner admin])
        .exists?
    end

    def platform_admin?(user)
      user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN") || user.has_role?("CORE_ADMIN")
    end
    private_class_method :platform_admin?
  end
end
