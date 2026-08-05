# frozen_string_literal: true

module Catalog
  # Organizer-only access to product access rows. Non-admin users see the
  # structural fields but never internal counters; admins get everything.
  class ProductAccessPolicy < Core::ApplicationPolicy
    VENUE_COUNTERS = %i[
      id event_product_id event_date_id type required_access_protection
      usage_limit opens_offset_seconds closes_offset_seconds
      created_at updated_at
    ].freeze

    VISIBILITY = {
      index: {
        default: { fields: VENUE_COUNTERS, include: [] },
        admin:   { include: :all, fields: :all }
      },
      replace: {
        default: { fields: VENUE_COUNTERS, include: [] },
        admin:   { include: :all, fields: :all }
      }
    }.freeze

    def index?   = organizer?
    def replace? = organizer?

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        manageable_events = Events::AuthorizationResolver.manageable_catalog_events(user)
        scope.joins(event_product: :event)
             .where(events_events: { id: manageable_events.select(:id) })
      end
    end

    private

    def organizer?
      Events::AuthorizationResolver.can_manage_catalog?(user, record.event_product.event)
    end
  end
end
