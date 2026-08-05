# frozen_string_literal: true

module Ticketing
  # Organizer-scoped policy for ticket-only behavior attached to products.
  class TicketTypePolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id event_product_id approval_mode audience date_selection waitlist_enabled
      transferable transfer_cutoff_seconds_before_start admissions_per_unit
      delegation_enabled delegation_validation_mode entry_validation_mode
      max_packages_per_user resale_enabled resale_cutoff_seconds_before_start
      resale_price_cap_type resale_fixed_cap_minor resale_fixed_cap_currency
      resale_percentage_cap_bps max_completed_resales created_at updated_at
    ].freeze

    def show? = organizer?
    def create? = organizer?
    def update? = organizer?
    def destroy? = organizer?

    VISIBILITY = {
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      create: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      update: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      destroy: { default: { fields: [], include: [] }, admin: { fields: :all, include: :all } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        manageable_events = Events::AuthorizationResolver.manageable_catalog_events(user)
        scope.joins(:event_product).where(catalog_event_products: { event_id: manageable_events.select(:id) })
      end
    end

    private

    def organizer?
      product = record.event_product
      product.present? && Events::AuthorizationResolver.can_manage_catalog?(user, product.event)
    end
  end
end
