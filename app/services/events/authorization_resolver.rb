# frozen_string_literal: true

module Events
  module AuthorizationResolver
    module_function

    def access_granted?(user, event)
      return false if user.nil? || event.nil?
      return true if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN") || user.has_role?("CORE_ADMIN")

      Events::AuthorizationResolver.organization_admin_or_owner?(user, event) ||
        Events::AuthorizationResolver.active_assignment?(user, event)
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

      assignment = event.event_staff_assignments
                     .where(user:, status: "active")
                     .first
      return assignment.role.to_sym if assignment

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
  end
end
