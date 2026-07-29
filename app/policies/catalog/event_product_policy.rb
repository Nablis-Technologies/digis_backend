# frozen_string_literal: true

module Catalog
  # Organizer-scoped authorization for product lifecycle actions. All actions
  # require organizer-level access to the parent event. Public product browsing
  # (active-only) is handled by a separate public endpoint.
  class EventProductPolicy < Core::ApplicationPolicy
    def index?  = organizer?
    def show?   = organizer?
    def create? = organizer?
    def update? = organizer?
    def destroy? = organizer?
    def activate?   = organizer?
    def deactivate? = organizer?

    VISIBILITY = {
      index: {
        default: { fields: :all, include: [] },
        admin: { include: :all, fields: :all }
      },
      show: {
        default: { fields: :all, include: [] },
        admin: { include: :all, fields: :all }
      },
      create: {
        default: { fields: :all, include: [ :ticket_type ] },
        admin: { include: :all, fields: :all }
      },
      update: {
        default: { fields: :all, include: [ :ticket_type ] },
        admin: { include: :all, fields: :all }
      }
    }.freeze

    private

    def organizer?
      Events::AuthorizationResolver.can_manage_catalog?(user, record.event)
    end

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        manageable_events = Events::AuthorizationResolver.manageable_catalog_events(user)
        scope.where(event_id: manageable_events.select(:id))
      end
    end
  end
end
