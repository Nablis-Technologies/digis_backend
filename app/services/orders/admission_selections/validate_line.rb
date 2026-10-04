# frozen_string_literal: true

module Orders
  module AdmissionSelections
    # Applies product and payload rules shared by checkout creation and guest OTP preflight.
    class ValidateLine < Core::BaseService
      def initialize(item:, product:)
        @item = item
        @product = product
      end

      def call
        product.ticket? ? validate_ticket_line : validate_add_on_line
      end

      private

      def validate_ticket_line
        return failure(error("product_unavailable", status: :unprocessable_entity)) unless product.ticket_type.present?
        return failure(error("admission_selection_invalid")) unless item[:answers] && item[:consents]
        return failure(error("admission_selection_invalid")) if item[:event_date_ids].present?

        success(:ticket)
      end

      def validate_add_on_line
        return failure(error("product_unavailable")) unless
          Catalog::EventProduct::ADMISSION_ADD_ON_TYPES.include?(product.type)
        return failure(error("admission_selection_invalid")) if ticket_only_input?
        return validate_parking_line if product.parking?

        result = Catalog::AddOns::ValidateProduct.call(product:)
        return failure(result.error) if result.failure?

        success(:add_on)
      end

      def validate_parking_line
        return success(:add_on) if product.product_accesses.any?(&:parking?)

        failure(error("product_unavailable", status: :unprocessable_entity))
      end

      def ticket_only_input?
        item[:registration_id].present? || item[:selected_event_date_id].present? || item[:answers].present? ||
          item[:consents].present? || item[:audience_proof].present?
      end

      def error(code, status: :unprocessable_entity)
        Core::BusinessError.new(I18n.t("orders.checkout.errors.#{code}"), code:, status:)
      end

      attr_reader :item, :product
    end
  end
end
