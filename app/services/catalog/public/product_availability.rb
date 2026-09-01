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
        return false unless sales_window_open?(product)
        return true if product.inventory_mode == "unlimited"

        product.inventories.any?(&:available?)
      end

      def sales_window_open?(product)
        (product.sales_start_at.blank? || product.sales_start_at <= at) &&
          (product.sales_end_at.blank? || product.sales_end_at > at)
      end
    end
  end
end
