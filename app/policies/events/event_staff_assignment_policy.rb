# frozen_string_literal: true

module Events
  class EventStaffAssignmentPolicy < Core::ApplicationPolicy
    def index? = Events::AuthorizationResolver.access_granted?(user, record.event)
    def show?  = Events::AuthorizationResolver.access_granted?(user, record.event)
    def create? = Events::AuthorizationResolver.can_assign?(user, record.event, record.role)
    def update? = Events::AuthorizationResolver.can_assign?(user, record.event, record.role)
    def destroy? = Events::AuthorizationResolver.can_assign?(user, record.event, record.role)

    VISIBILITY = {
      index: { default: { fields: :all, include: :all }, admin: { fields: :all, include: :all } },
      show:  { default: { fields: :all, include: :all }, admin: { fields: :all, include: :all } }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")

        event_ids = Events::EventPolicy::Scope.new(user, Events::Event).resolve.pluck(:id)
        scope.where(event_id: event_ids)
      end
    end
  end
end
