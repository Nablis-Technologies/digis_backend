# frozen_string_literal: true

module Catalog
  module Public
    # Computes attendee-safe availability from preloaded product state without
    # exposing inventory counters or changing the reservation authority.
    class ProductAvailability
      def self.for(products:, at: Time.current)
        new(products:, at:).call
      end

      def initialize(products:, at:)
        @products = products
        @at = at.to_time
      end

      def call
        products.to_h { |product| [ product.id, available?(product) ] }
      end

      private

      attr_reader :products, :at

      def available?(product)
        return false unless Catalog::Products::SalesWindow.open?(product, at:)
        return true if product.inventory_mode == "unlimited"

        product.inventories.any?(&:available?)
      end
    end
  end
end
