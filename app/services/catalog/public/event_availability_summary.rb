# frozen_string_literal: true

module Catalog
  module Public
    # Builds attendee-safe discovery fields for a bounded event page. Ticket
    # child rows are streamed in fixed-size batches without business-result caps.
    class EventAvailabilitySummary
      TICKET_STATE_PRECEDENCE = %w[available unavailable coming_soon sold_out sales_closed].freeze
      PRODUCT_BATCH_SIZE = 100

      def self.call(events:, at:, currency: nil)
        new(events:, at:, currency:).call
      end

      def initialize(events:, at:, currency: nil)
        @events = Array(events)
        @at = at.to_time
        @currency = currency.to_s.upcase.presence
      end

      def call
        counts = active_public_ticket_counts
        lifecycle_by_id = event_lifecycle_by_event_id
        summaries = events.to_h { |event| [ event.id, empty_offer_summary ] }
        each_ticket_product_batch do |products|
          event_map = events.index_by { |event| event.id.to_s }
          batch_event_map = event_map.slice(*products.map { |product| product.event_id.to_s }.uniq)
          states = ProductAvailability.for(
            products:,
            events_by_id: batch_event_map,
            event_dates_by_id: event_dates_by_event_id(products),
            at:
          )
          products.each { |product| record_offer_state!(summaries.fetch(product.event_id), states.fetch(product.id)) }
        end
        prices_by_event = price_from_minor_by_event_id

        events.to_h do |event|
          [
            event.id,
            {
              event_lifecycle: lifecycle_by_id.fetch(event.id, "unscheduled"),
              ticket_availability: ticket_state_for(event, counts, summaries.fetch(event.id)),
              price_from_minor: prices_by_event[event.id.to_s],
              price_from_currency: currency || event.currency
            }
          ]
        end
      end

      private

      attr_reader :events, :at, :currency

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
          .includes(:ticket_type, :prices, :inventories, product_accesses: :event_date)
          .find_in_batches(batch_size: PRODUCT_BATCH_SIZE) { |batch| yield batch }
      end

      def event_dates_by_event_id(products)
        products.flat_map(&:product_accesses)
          .filter_map(&:event_date)
          .uniq(&:id)
          .group_by { |event_date| event_date.event_id.to_s }
      end

      def price_from_minor_by_event_id
        return {} if events.empty?

        prices = Catalog::ProductPrice.joins(event_product: :ticket_type)
          .where(catalog_event_products: { event_id: event_ids, status: "active", type: "ticket" })
          .where(ticketing_ticket_types: { audience: "public" })
          .where("catalog_product_prices.active_from <= ?", at)
          .where("catalog_product_prices.active_to IS NULL OR catalog_product_prices.active_to > ?", at)
        prices = if currency
          prices.where(catalog_product_prices: { currency: })
        else
          prices.joins("INNER JOIN events_events ON events_events.id = catalog_event_products.event_id")
            .where("catalog_product_prices.currency = events_events.currency")
        end
        prices
          .group("catalog_event_products.event_id")
          .minimum(:amount_minor)
          .transform_keys(&:to_s)
      end

      def event_lifecycle_by_event_id
        return {} if events.empty?

        ongoing = Arel.sql(
          "BOOL_OR(status = 'scheduled' AND starts_at <= ? AND ends_at > ?)", at, at
        )
        upcoming = Arel.sql("BOOL_OR(status = 'scheduled' AND starts_at > ?)", at)
        ended = Arel.sql(
          "BOOL_OR(status = 'completed' OR (status = 'scheduled' AND ends_at <= ?))", at
        )

        Events::EventDate.where(event_id: event_ids).group(:event_id).pluck(:event_id, ongoing, upcoming, ended)
          .to_h do |event_id, is_ongoing, is_upcoming, is_ended|
            state = if is_ongoing
              "ongoing"
            elsif is_upcoming
              "upcoming"
            elsif is_ended
              "ended"
            else
              "unscheduled"
            end
            [ event_id, state ]
          end
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
