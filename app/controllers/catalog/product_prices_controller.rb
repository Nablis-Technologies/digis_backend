# frozen_string_literal: true

module Catalog
  class ProductPricesController < Catalog::ApplicationController
    include Core::Common

    PRICE_FIELDS = %i[
      id type currency amount_minor active_from active_to
      ticket_type_id event_product_id
    ].freeze

    self.model_class = Catalog::ProductPrice
    self.default_serializer = Catalog::ProductPriceSerializer

    def create
      product = Catalog::EventProduct.find(params[:product_id])
      authorize Catalog::ProductPrice.new(event_product: product), :create?

      result = Catalog::Pricing::CreatePrice.new(
        event_product: product,
        attributes: model_params.to_h
      ).call

      if result.success?
        render_success(data: result.value)
      else
        render_error(result.error.message, status: :unprocessable_entity)
      end
    end

    private

    def model_params
      params.permit(:type, :currency, :amount_minor, :active_from, :active_to, :ticket_type_id)
    end

    def eager_load_config
      { default: [] }
    end

    def allowed_order_columns
      %w[id type currency amount_minor active_from active_to created_at]
    end

    def serializer_profile
      {
        index: { fields: PRICE_FIELDS, include: [] },
        show: { fields: PRICE_FIELDS, include: [] },
        create: { fields: PRICE_FIELDS, include: [] }
      }
    end
  end
end
