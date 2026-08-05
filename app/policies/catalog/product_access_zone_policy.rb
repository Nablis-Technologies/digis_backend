# frozen_string_literal: true

module Catalog
  # Organizer-only access to zone grants. Scoping resolves through the
  # product access → product → event chain to the user's manageable events.
  class ProductAccessZonePolicy < Core::ApplicationPolicy
    VISIBILITY = {
      index: {
        default: { fields: :all, include: [] },
        admin:   { include: :all, fields: :all }
      },
      replace: {
        default: { fields: :all, include: [] },
        admin:   { include: :all, fields: :all }
      }
    }.freeze

    def index?   = organizer?
    def replace? = organizer?

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        manageable_events = Events::AuthorizationResolver.manageable_catalog_events(user)
        scope.joins(product_access: { event_product: :event })
             .where(events_events: { id: manageable_events.select(:id) })
      end
    end

    private

    def organizer?
      Events::AuthorizationResolver.can_manage_catalog?(
        user,
        record.product_access.event_product.event
      )
    end
  end
end
