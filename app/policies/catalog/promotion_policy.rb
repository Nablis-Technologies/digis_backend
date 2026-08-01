# frozen_string_literal: true

module Catalog
  # Organizer-scoped policy for buyer promotion definitions and quotes.
  class PromotionPolicy < Core::ApplicationPolicy
    def index?  = manageable_events.exists?
    def show?   = manageable_event?
    def create? = manageable_event?
    def update? = manageable_event?
    def destroy? = manageable_event?
    def publish? = manageable_event?
    def disable? = manageable_event?
    def quote? = manageable_event?

    VISIBILITY = {
      index: {
        default: { fields: :all, include: [] },
        admin: { fields: :all, include: :all }
      },
      show: {
        default: { fields: :all, include: [ :promotion_codes ] },
        admin: { fields: :all, include: :all }
      },
      create: {
        default: { fields: :all, include: [] },
        admin: { fields: :all, include: :all }
      },
      update: {
        default: { fields: :all, include: [] },
        admin: { fields: :all, include: :all }
      },
      destroy: {
        default: { fields: [], include: [] },
        admin: { fields: :all, include: :all }
      },
      publish: {
        default: { fields: :all, include: [] },
        admin: { fields: :all, include: :all }
      },
      disable: {
        default: { fields: :all, include: [] },
        admin: { fields: :all, include: :all }
      },
      quote: {
        default: { fields: :all, include: [] },
        admin: { fields: :all, include: :all }
      }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        manageable_events = Events::AuthorizationResolver.manageable_catalog_events(user)
        scope.where(event_id: manageable_events.select(:id))
      end
    end

    private

    def manageable_event?
      record.event.present? && Events::AuthorizationResolver.can_manage_catalog?(user, record.event)
    end

    def manageable_events
      Events::AuthorizationResolver.manageable_catalog_events(user)
    end
  end
end
