# frozen_string_literal: true

module Parking
  # Fulfills every unit of one paid parking order item. Existing tickets are
  # reused by the package source/unit unique identity, so payment/outbox
  # retries cannot issue a second parking credential.
  class FulfillOrderItem < Core::BaseService
    def initialize(order_item:, event: nil, issuance_context: nil, existing_tickets: nil)
      @order_item = order_item
      @event = event
      @issuance_context = issuance_context
      @existing_tickets = existing_tickets
    end

    def call
      item = locked_order_item
      return failure(error(:source_not_fulfillable)) unless fulfillable?(item)
      return failure(error(:product_access_missing, :unprocessable_entity)) if parking_accesses(item).empty?

      existing = @existing_tickets || Ticketing::Ticket.includes(
        :event,
        :admission_slots,
        { current_credential_generation: :credentials },
        registration: :consent_requirements,
        event_product: [ :ticket_type, { product_accesses: :event_date } ]
      ).where(order_item_id: item.id).to_a.index_by(&:unit_number)
      tickets = (1..item.quantity).map do |unit_number|
        result = Parking::IssuePackage.call(
          order_item: item,
          unit_number:,
          event: @event || item.order.event,
          existing_ticket: existing[unit_number] || existing[[ item.id, unit_number ]],
          issuance_context: @issuance_context
        )
        return failure(result.error) if result.failure?

        result.value
      end
      success(tickets)
    rescue ActiveRecord::RecordNotFound
      failure(error(:source_not_found, :not_found))
    end

    private

    def locked_order_item
      Orders::OrderItem.includes(
        { order: :event },
        event_product: :product_accesses
      ).lock.find(@order_item.id)
    end

    def fulfillable?(item)
      item.fulfilled? && item.order.status == "fulfilled" &&
        item.type_snapshot == "parking" && item.event_product.parking?
    end

    def parking_accesses(item)
      item.event_product.product_accesses.select(&:parking?)
    end

    def error(key, status: :conflict)
      Core::BusinessError.new(
        I18n.t("parking.errors.#{key}"),
        code: "parking_#{key}",
        status:
      )
    end
  end
end
