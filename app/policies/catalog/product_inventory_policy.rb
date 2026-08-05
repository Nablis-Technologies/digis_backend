# frozen_string_literal: true

module Catalog
  # Inventory counter visibility is restricted to organizers with catalogue
  # management permission. Non-admin users see only structural fields
  # (id, event_product_id, event_date_id, timestamps); operational counters
  # (capacity, held_count, sold_count, lock_version) are admin-only.
  class ProductInventoryPolicy < Core::ApplicationPolicy
    def index?  = Events::AuthorizationResolver.manageable_catalog_events(user).exists?
    def show?   = organizer?

    VISIBILITY = {
      index: {
        default: { fields: %i[id event_product_id event_date_id created_at updated_at], include: [] },
        admin: { include: :all, fields: :all }
      },
      show: {
        default: { fields: %i[id event_product_id event_date_id created_at updated_at], include: [] },
        admin: { include: :all, fields: :all }
      }
    }.freeze

    private

    def organizer?
      Events::AuthorizationResolver.can_manage_catalog?(user, record.event_product&.event)
    end

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        manageable_events = Events::AuthorizationResolver.manageable_catalog_events(user)
        scope.joins(:event_product).where(catalog_event_products: { event_id: manageable_events.select(:id) })
      end
    end
  end
end
