# frozen_string_literal: true

module Catalog
  # Read-only admin endpoint for inventory state.
  class ProductInventoriesController < Catalog::ApplicationController
    include Core::Common

    INVENTORY_FIELDS = %i[
      id event_product_id event_date_id capacity
      held_count sold_count lock_version
      created_at updated_at
    ].freeze

    self.model_class = Catalog::ProductInventory
    self.default_serializer = Catalog::ProductInventorySerializer

    private

    def model_params
      params.permit(:event_product_id, :event_date_id, :capacity)
    end

    def eager_load_config
      { default: %i[event_product event_date] }
    end

    def allowed_order_columns
      %w[id event_product_id capacity held_count sold_count created_at]
    end

    def serializer_profile
      {
        index: { fields: INVENTORY_FIELDS, include: [] },
        show: { fields: INVENTORY_FIELDS, include: [] }
      }
    end
  end
end
