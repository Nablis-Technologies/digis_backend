# frozen_string_literal: true

module Catalog
  # Organizer-scoped read/replace endpoints for a product's date allocations.
  # The product lookup is restricted to events the current user can manage;
  # index authorizes :show? on the product and replace authorizes :update?.
  class ProductDateAllocationsController < Catalog::ApplicationController
    FIELDS = %i[id event_product_id event_date_id allocation_basis_points created_at updated_at].freeze

    before_action :find_product
    before_action -> { authorize @product, :show? }, only: :index

    def index
      result = authorized_scope(@product.product_date_allocations).includes(:event_date).order(:created_at)
      render_success(data: result)
    end

    def replace
      authorize @product, :update?

      outcome = Catalog::DateAllocations::Replace.call(
        product: @product,
        allocations: replace_params
      )

      if outcome.success?
        render_success(data: outcome.value.product_date_allocations.includes(:event_date).order(:created_at))
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
      params.require(:allocations).map do |alloc|
        alloc.permit(:event_date_id, :allocation_basis_points)
      end
    end
  end
end
