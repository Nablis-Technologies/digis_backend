# frozen_string_literal: true

module Ticketing
  # Organizer-scoped policy for access-code metadata and lifecycle records.
  class AccessCodePolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id ticket_type_id label max_uses used_count max_quantity_per_use
      starts_at expires_at active created_at updated_at
    ].freeze

    def index? = organizer?
    def show? = organizer?
    def create? = organizer?
    def destroy? = organizer?

    VISIBILITY = {
      index: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      create: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      destroy: { default: { fields: [], include: [] }, admin: { fields: :all, include: :all } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        manageable_events = Events::AuthorizationResolver.manageable_catalog_events(user)
        scope.joins(ticket_type: :event_product)
          .where(catalog_event_products: { event_id: manageable_events.select(:id) })
      end
    end

    private

    def organizer?
      ticket_type = record.ticket_type
      product = ticket_type&.event_product
      product.present? && Events::AuthorizationResolver.can_manage_catalog?(user, product.event)
    end
  end
end
