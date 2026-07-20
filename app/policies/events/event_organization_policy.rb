# frozen_string_literal: true

module Events
  class EventOrganizationPolicy < Core::ApplicationPolicy
    def index? = Events::AuthorizationResolver.access_granted?(user, record.event)
    def show?  = Events::AuthorizationResolver.access_granted?(user, record.event)
    def create? = Events::AuthorizationResolver.organization_admin_or_owner?(user, record.event)
    def update? = Events::AuthorizationResolver.organization_admin_or_owner?(user, record.event)
    def destroy? = Events::AuthorizationResolver.organization_admin_or_owner?(user, record.event)

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")

        event_ids = Events::EventPolicy::Scope.new(user, Events::Event).resolve.pluck(:id)
        scope.where(event_id: event_ids)
      end
    end
  end
end
