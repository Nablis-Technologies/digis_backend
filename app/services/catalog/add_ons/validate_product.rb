# frozen_string_literal: true

module Catalog
  module AddOns
    # Defines the noncredential product types that the generic add-on
    # fulfillment boundary may complete. Parking is intentionally owned by the
    # later credential-issuing parking workflow.
    class ValidateProduct < Core::BaseService
      FULFILLABLE_TYPES = %w[merchandise food donation digital_addon].freeze

      def initialize(product:, custom_amount_minor: nil)
        @product = product
        @custom_amount_minor = custom_amount_minor
      end

      def call
        return failure(error(:product_required)) unless @product.is_a?(Catalog::EventProduct)
        return failure(error(:unsupported_add_on_type)) unless FULFILLABLE_TYPES.include?(@product.type)
        return failure(error(:custom_price_not_allowed)) unless custom_price_allowed?
        return failure(error(:custom_amount_invalid)) unless custom_amount_valid?

        success(@product)
      end

      private

      def custom_price_allowed?
        return true if @custom_amount_minor.nil?

        @product.type == "donation" && @product.allow_custom_price
      end

      def custom_amount_valid?
        return true if @custom_amount_minor.nil?

        @custom_amount_minor.is_a?(Integer) && @custom_amount_minor.positive?
      end

      def error(key)
        Core::BusinessError.new(
          I18n.t("catalog.add_ons.errors.#{key}"),
          code: key,
          status: :unprocessable_entity
        )
      end
    end
  end
end
