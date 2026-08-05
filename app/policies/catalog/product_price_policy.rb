# frozen_string_literal: true

module Catalog
  class ProductPricePolicy < Core::ApplicationPolicy
    def index?  = Events::AuthorizationResolver.manageable_catalog_events(user).exists?
    def show?   = Events::AuthorizationResolver.can_manage_catalog?(user, record.event_product&.event)
    def create? = Events::AuthorizationResolver.can_manage_catalog?(user, record.event_product&.event)

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
        default: { fields: :all, include: [] },
        admin: { include: :all, fields: :all }
      }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        manageable_events = Events::AuthorizationResolver.manageable_catalog_events(user)
        scope.joins(:event_product).where(catalog_event_products: { event_id: manageable_events.select(:id) })
      end
    end
  end
end
