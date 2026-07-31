# frozen_string_literal: true

module Catalog
  # Organizer-only access to date allocations. Non-admin users see structural
  # fields only; admins get everything.
  class ProductDateAllocationPolicy < Core::ApplicationPolicy
    FIELDS = %i[id event_product_id event_date_id allocation_basis_points created_at updated_at].freeze

    VISIBILITY = {
      index: {
        default: { fields: FIELDS, include: [] },
        admin:   { include: :all, fields: :all }
      },
      replace: {
        default: { fields: FIELDS, include: [] },
        admin:   { include: :all, fields: :all }
      }
    }.freeze

    def index?   = organizer?
    def replace? = organizer?

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        manageable_events = Events::AuthorizationResolver.manageable_catalog_events(user)
        scope.joins(:event_product)
             .where(catalog_event_products: { event_id: manageable_events.select(:id) })
      end
    end

    private

    def organizer?
      Events::AuthorizationResolver.can_manage_catalog?(user, record.event_product.event)
    end
  end
end
