# frozen_string_literal: true

require "set"

module Ticketing
  module OutboxHandlers
    # Bridges Orders fulfillment into one idempotent Ticketing issuance call
    # per ticket-product unit. Non-ticket order items remain owned by their
    # domain and are intentionally ignored here.
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

          event_id = items.first&.order&.event_id || @event.payload.fetch("event_id")
          Core::Database::AdvisoryLock.acquire!("ticketing-package-issuance", event_id)
          context = issuance_context(event_id)
          existing_tickets = Ticketing::Ticket.where(order_item_id: items.map(&:id)).to_a.index_by do |ticket|
            [ ticket.order_item_id, ticket.unit_number ]
          end

          items.each do |item|
            next unless item.type_snapshot == "ticket"

            1.upto(item.quantity) do |unit_number|
              issuance = Ticketing::Packages::Issue.call(
                order_item: item,
                unit_number:,
                source: item,
                existing_ticket: existing_tickets[[ item.id, unit_number ]],
                reload_ticket: false,
                issuance_context: context
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
          reserved_lookup_codes: Ticketing::Credential.where(event_id:).where.not(lookup_code: nil).pluck(:lookup_code).to_set,
          next_index_version: Ticketing::AttendeeIndexEntry.where(event_id:).maximum(:index_version).to_i + 1
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
