# frozen_string_literal: true

module Catalog
  # Organizer-scoped read/replace endpoints for the zone grants of one
  # product access row. Both the access lookup and the index authorize against
  # the manageable-events scope so no data leaks to non-organizers.
  class ProductAccessZonesController < Catalog::ApplicationController
    before_action :find_product_access
    before_action -> { authorize @product_access, :index? }, only: :index

    def index
      zones = authorized_scope(@product_access.product_access_zones).includes(:access_zone)
      render_success(data: zones)
    end

    def replace
      authorize @product_access.event_product, :update?

      outcome = Catalog::Zones::ReplaceGrants.call(
        product_access: @product_access,
        zone_ids: params[:zone_ids] || []
      )

      if outcome.success?
        render_success(data: outcome.value.product_access_zones.includes(:access_zone))
      else
        render_error(outcome.error, status: :unprocessable_entity)
      end
    end

    private

    def find_product_access
      manageable_events = Events::AuthorizationResolver.manageable_catalog_events(current_user)
      @product_access = Catalog::ProductAccess
        .joins(event_product: :event)
        .where(events_events: { id: manageable_events.select(:id) })
        .find(params[:product_access_id])
    end
  end
end
