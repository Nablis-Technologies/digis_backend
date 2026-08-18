# frozen_string_literal: true

module Marketplace
  # Organizer-only authorization for the ticket-type resale policy. The
  # policy is event-scoped, so an organizer cannot alter another event's
  # resale rules by guessing a ticket-type ID.
  class ResalePolicyPolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id event_product_id resale_enabled resale_cutoff_seconds_before_start resale_price_cap_type
      resale_fixed_cap_minor resale_fixed_cap_currency resale_percentage_cap_bps max_completed_resales
      created_at updated_at
    ].freeze

    def show? = manageable_event?

    def update? = manageable_event?

    VISIBILITY = {
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: [] } },
      update: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        events = Events::AuthorizationResolver.manageable_catalog_events(user)
        scope.joins(:event_product).where(catalog_event_products: { event_id: events.select(:id) })
      end
    end

    private

    def manageable_event?
      return false unless record&.event_product&.event

      Events::AuthorizationResolver.can_manage_catalog?(user, record.event_product.event)
    end
  end
end
