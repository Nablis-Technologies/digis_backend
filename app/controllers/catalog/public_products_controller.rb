# frozen_string_literal: true

module Catalog
  # Public read-only product surface for published public events. Prices,
  # inventory counters, promotion material, and organizer-only metadata stay
  # behind authenticated catalog endpoints.
  class PublicProductsController < Events::ApplicationController
    skip_before_action :authenticate_user
    skip_authorization only: :index

    def index
      event = Events::Event.publicly_visible.find_by(slug: params[:event_slug])
      return render_error(I18n.t("errors.not_found", model: "event"), status: :not_found) unless event

      products = event.event_products.active.includes(:ticket_type).order(:sort_order, :created_at)
      render_success(data: products, serializer_options: { serializer: Catalog::Public::EventProductSerializer })
    end
  end
end
