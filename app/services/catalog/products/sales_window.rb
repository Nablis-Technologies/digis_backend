# frozen_string_literal: true

module Catalog
  module Products
    # Owns end-exclusive product sales-window semantics for inventory,
    # waitlist, and attendee-facing availability paths.
    class SalesWindow
      def self.error_key(product, at: Time.current)
        return :sales_not_started if product.sales_start_at.present? && product.sales_start_at > at
        return :sales_ended if product.sales_end_at.present? && product.sales_end_at <= at

        nil
      end

      def self.open?(product, at: Time.current)
        error_key(product, at:).nil?
      end
    end
  end
end
