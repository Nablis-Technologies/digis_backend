# frozen_string_literal: true

module Parking
  # Issues one parking package unit through the shared Ticketing credential
  # pipeline. Parking has no registration or ticket-type row, but it receives
  # the same revocable QR/PNR and admission-slot semantics as other controlled
  # access packages.
  class IssuePackage < Core::BaseService
    def initialize(order_item:, unit_number:, event: nil, existing_ticket: nil, issuance_context: nil)
      @order_item = order_item
      @unit_number = unit_number
      @event = event
      @existing_ticket = existing_ticket
      @issuance_context = issuance_context
    end

    def call
      return failure(error(:source_type_invalid, :unprocessable_entity)) unless parking_item?

      options = {
        order_item: @order_item,
        unit_number: @unit_number,
        issuance_context: @issuance_context
      }
      options[:event] = @event if @event
      options[:existing_ticket] = @existing_ticket if @existing_ticket
      result = Ticketing::Packages::Issue.call(**options)
      return failure(result.error) if result.failure?

      success(result.value)
    rescue ActiveRecord::RecordNotFound
      failure(error(:source_not_found, :not_found))
    end

    private

    def parking_item?
      @order_item.is_a?(Orders::OrderItem) &&
        @order_item.type_snapshot == "parking" &&
        @order_item.event_product.parking?
    end

    def error(key, status)
      Core::BusinessError.new(
        I18n.t("parking.errors.#{key}"),
        code: "parking_#{key}",
        status:
      )
    end
  end
end
