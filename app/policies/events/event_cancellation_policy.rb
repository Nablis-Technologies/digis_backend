# frozen_string_literal: true

module Events
  class EventCancellationPolicy < Core::ApplicationPolicy
    def index?  = Events::AuthorizationResolver.access_granted?(user, record.event)
    def show?   = Events::AuthorizationResolver.access_granted?(user, record.event)
    # Cancellation is an irreversible financial command. Event managers and
    # collaborators may manage catalog work, but only platform administrators
    # or primary-organization owners/admins can cross this boundary.
    def create?
      return true if platform_admin?
      return false unless user && record.event

      Organizations::Membership.where(
        user:, organization: record.event.organization, status: "active", role: %w[owner admin]
      ).exists?
    end

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

    private

    def platform_admin?
      user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
    end
  end
end
