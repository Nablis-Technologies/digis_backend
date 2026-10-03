# frozen_string_literal: true

module Catalog
  module Public
    # Builds attendee-safe discovery fields for a bounded event page. Ticket
    # child rows are streamed in fixed-size batches without business-result caps.
    class EventAvailabilitySummary
      TICKET_STATE_PRECEDENCE = %w[available unavailable coming_soon sold_out sales_closed].freeze
      PRODUCT_BATCH_SIZE = 100

      def self.call(events:, at:)
        new(events:, at:).call
      end

      def initialize(events:, at:)
        @events = Array(events)
        @at = at.to_time
      end

      def call
        counts = active_public_ticket_counts
        summaries = events.to_h { |event| [ event.id, empty_offer_summary ] }
        each_ticket_product_batch do |products|
          event_map = events.index_by { |event| event.id.to_s }
          batch_event_map = event_map.slice(*products.map { |product| product.event_id.to_s }.uniq)
          states = ProductAvailability.for(products:, events_by_id: batch_event_map, at:)
          products.each { |product| record_offer_state!(summaries.fetch(product.event_id), states.fetch(product.id)) }
        end
        prices_by_event = price_from_minor_by_event_id

        events.to_h do |event|
          [
            event.id,
            {
              event_lifecycle: lifecycle_for(event),
              ticket_availability: ticket_state_for(event, counts, summaries.fetch(event.id)),
              price_from_minor: prices_by_event[event.id.to_s]
            }
          ]
        end
      end

      private

      attr_reader :events, :at

      def active_public_ticket_counts
        return {} if events.empty?

        results = Catalog::EventProduct.active.tickets.left_outer_joins(:ticket_type)
          .where(event_id: event_ids)
          .group(:event_id)
          .pluck(
            :event_id,
            Arel.sql("COUNT(ticketing_ticket_types.id) FILTER (WHERE ticketing_ticket_types.audience = 'public')"),
            Arel.sql("COUNT(catalog_event_products.id) FILTER (WHERE ticketing_ticket_types.id IS NULL)")
          )
        public_counts = results.to_h { |event_id, count, _missing| [ event_id, count ] }
        missing_type_counts = results.to_h { |event_id, _count, missing| [ event_id, missing ] }
        { public: public_counts, missing_ticket_type: missing_type_counts }
      end

      def empty_offer_summary
        { product_count: 0, eligible_product_count: 0, states: Hash.new(false) }
      end

      def record_offer_state!(summary, state)
        summary[:product_count] += 1
        if state == "no_eligible_dates"
          summary[:states][:no_eligible_dates] = true
        else
          summary[:eligible_product_count] += 1
          summary[:states][state.to_sym] = true
        end
      end

      def each_ticket_product_batch
        return if events.empty?

        Catalog::EventProduct.active.tickets.joins(:ticket_type)
          .where(event_id: event_ids, ticketing_ticket_types: { audience: "public" })
          .includes(:ticket_type, :prices, :inventories, :product_accesses)
          .find_in_batches(batch_size: PRODUCT_BATCH_SIZE) { |batch| yield batch }
      end

      def price_from_minor_by_event_id
        return {} if events.empty?

        Catalog::ProductPrice.joins(event_product: :ticket_type)
          .joins("INNER JOIN events_events ON events_events.id = catalog_event_products.event_id")
          .where(catalog_event_products: { event_id: event_ids, status: "active", type: "ticket" })
          .where(ticketing_ticket_types: { audience: "public" })
          .where("catalog_product_prices.currency = events_events.currency")
          .where("catalog_product_prices.active_from <= ?", at)
          .where("catalog_product_prices.active_to IS NULL OR catalog_product_prices.active_to > ?", at)
          .group("catalog_event_products.event_id")
          .minimum(:amount_minor)
          .transform_keys(&:to_s)
      end

      def lifecycle_for(event)
        dates = event.event_dates.to_a
        scheduled_dates = dates.select { |date| date.status == "scheduled" }
        return "ongoing" if scheduled_dates.any? { |date| date.starts_at <= at && date.ends_at > at }
        return "upcoming" if scheduled_dates.any? { |date| date.starts_at > at }

        ended = dates.any? do |date|
          date.status == "completed" || (date.status == "scheduled" && date.ends_at <= at)
        end
        ended ? "ended" : "unscheduled"
      end

      def ticket_state_for(event, counts, summary)
        return "unavailable" if counts.fetch(:missing_ticket_type).fetch(event.id, 0).positive?

        count = counts.fetch(:public).fetch(event.id, 0)
        return "no_public_tickets" if count.zero?
        return "unavailable" unless summary[:product_count] == count
        return "no_eligible_dates" if summary[:eligible_product_count].zero?

        TICKET_STATE_PRECEDENCE.find { |state| summary[:states][state.to_sym] } || "unavailable"
      end

      def event_ids
        events.map(&:id)
      end
    end
  end
end
