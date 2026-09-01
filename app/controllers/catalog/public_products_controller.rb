# frozen_string_literal: true

module Catalog
  # Public read-only product surface for published public events. Only safe
  # price options and a boolean availability projection cross this boundary;
  # counters, promotion material, and organizer-only metadata stay private.
  class PublicProductsController < Events::ApplicationController
    skip_before_action :authenticate_user
    skip_authorization only: :index

    def index
      event = Events::Event.publicly_visible.find_by(slug: params[:event_slug])
      return render_error(I18n.t("errors.not_found", model: "event"), status: :not_found) unless event

      at = Time.current
      products = event.event_products.active
        .includes(:ticket_type, :prices, :inventories)
        .order(:sort_order, :created_at)
      availability = Catalog::Public::ProductAvailability.for(products: products.to_a, at:)
      render_success(
        data: products,
        serializer_options: {
          serializer: Catalog::Public::EventProductSerializer,
          at:, availability:
        }
      )
    end
  end
end
