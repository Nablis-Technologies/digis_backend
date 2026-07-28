# frozen_string_literal: true

module Catalog
  module Pricing
    # Creates a product price with normalized currency and integer minor units.
    class CreatePrice < Core::BaseService
      def initialize(event_product:, attributes:)
        @event_product = event_product
        @attributes = attributes
      end

      def call
        price = Catalog::ProductPrice.new(@attributes.merge(event_product: @event_product))

        return failure(Core::Error.new(price.errors.full_messages.join(", "))) unless price.save

        success(price)
      end
    end
  end
end
