# frozen_string_literal: true

require "set"

module Ticketing
  module OutboxHandlers
    # Bridges Orders fulfillment into idempotent credential issuance for ticket
    # and parking product units. Merchandise, food, donation, and digital
    # add-ons remain owned by their noncredential fulfillment handlers.
    class OrderFulfilled < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        outcome = nil
        ActiveRecord::Base.transaction do
          items = order_items
          if items.length != @event.payload.fetch("order_item_ids").length
            outcome = failure(event_error)
            raise ActiveRecord::Rollback
          end
          gift_order_item_ids = Array(@event.payload["gift_order_item_ids"]).map(&:to_s)
          item_ids = items.map { |item| item.id.to_s }
          if gift_order_item_ids.uniq.length != gift_order_item_ids.length ||
              (gift_order_item_ids - item_ids).any? ||
              items.any? { |item| gift_order_item_ids.include?(item.id.to_s) && item.type_snapshot != "ticket" }
            outcome = failure(event_error)
            raise ActiveRecord::Rollback
          end

          event_id = items.first&.order&.event_id || @event.payload.fetch("event_id")
          event = Events::Event.lock.find(event_id)
          return success(items) if event.status == "cancelled"
          Core::Database::AdvisoryLock.acquire!("ticketing-package-issuance", event_id)
          Core::Database::AdvisoryLock.acquire!("ticketing-attendee-index", event_id)
          context = issuance_context(event_id)
          existing_tickets = Ticketing::Ticket.includes(
            :event,
            :admission_slots,
            { current_credential_generation: :credentials },
            registration: :consent_requirements,
            event_product: [ :ticket_type, { product_accesses: :event_date } ]
          ).where(order_item_id: items.map(&:id)).to_a.index_by do |ticket|
            [ ticket.order_item_id, ticket.unit_number ]
          end

          items.each do |item|
            next if gift_order_item_ids.include?(item.id.to_s)

            if item.type_snapshot == "parking"
              parking = Parking::FulfillOrderItem.call(
                order_item: item,
                event:,
                issuance_context: context,
                existing_tickets:
              )
              if parking.failure?
                outcome = failure(parking.error)
                raise ActiveRecord::Rollback
              end
              next
            end
            next unless item.type_snapshot == "ticket"

            1.upto(item.quantity) do |unit_number|
              issuance = Ticketing::Packages::Issue.call(
                order_item: item,
                unit_number:,
                source: item,
                existing_ticket: existing_tickets[[ item.id, unit_number ]],
                reload_ticket: false,
                issuance_context: context,
                event:, index_lock_held: true
              )
              next if issuance.success?

              outcome = failure(issuance.error)
              raise ActiveRecord::Rollback
            end
          end
          outcome = success(items)
        end
        outcome
      rescue KeyError
        failure(event_error)
      end

      private

      def order_items
        Orders::OrderItem.includes(
          { order: :event },
          { event_product: [ :ticket_type, { product_accesses: :event_date } ] },
          registration: [ :user, :consent_requirements ]
        ).where(id: @event.payload.fetch("order_item_ids")).lock.order(:id).to_a
      end

      def issuance_context(event_id)
        {
          reserved_lookup_codes: Ticketing::Credential.where(event_id:).where.not(lookup_code: nil).pluck(:lookup_code).to_set
        }
      end

      def event_error
        Core::BusinessError.new(
          I18n.t("ticketing.package_issuance.errors.invalid_fulfillment_event"),
          code: "invalid_fulfillment_event",
          status: :unprocessable_entity
        )
      end
    end
  end
end
