# frozen_string_literal: true

module Catalog
  # Organizer-scoped read/replace endpoints for a product's access rows.
  # The product lookup is restricted to events the current user can manage;
  # replace authorizes an explicit :update? on the parent product.
  class ProductAccessesController < Catalog::ApplicationController
    FIELDS = %i[
      id event_product_id event_date_id type required_access_protection
      usage_limit opens_offset_seconds closes_offset_seconds
      created_at updated_at
    ].freeze

    before_action :find_product

    def index
      result = authorized_scope(@product.product_accesses).order(:created_at)
      render_success(data: result, serializer_options: { fields: FIELDS, include: [] })
    end

    def replace
      authorize @product, :update?

      outcome = Catalog::Accesses::Replace.call(
        product: @product,
        accesses: replace_params
      )

      if outcome.success?
        render_success(data: outcome.value.product_accesses.order(:created_at))
      else
        render_error(outcome.error, status: :unprocessable_entity)
      end
    end

    private

    def find_product
      manageable_events = Events::AuthorizationResolver.manageable_catalog_events(current_user)
      @product = Catalog::EventProduct.where(event_id: manageable_events.select(:id)).find(params[:event_product_id])
    end

    def replace_params
      params.require(:accesses).map do |access|
        access.permit(:event_date_id, :type, :usage_limit,
                       :opens_offset_seconds, :closes_offset_seconds,
                       :required_access_protection)
      end
    end
  end
end
