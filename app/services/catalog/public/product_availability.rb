# frozen_string_literal: true

module Catalog
  module Public
    # Batches attendee-safe offer states from the associations preloaded for a
    # public page. Availability remains advisory; checkout revalidates it.
    class ProductAvailability
      def self.for(products:, events_by_id:, at: Time.current, event_dates_by_id: nil)
        new(products:, events_by_id:, at:, event_dates_by_id:).call
      end

      def initialize(products:, events_by_id:, at:, event_dates_by_id: nil)
        @products = Array(products)
        @events_by_id = events_by_id.transform_keys(&:to_s)
        @at = at.to_time
        @event_dates_by_id = event_dates_by_id&.transform_keys(&:to_s)
      end

      def call
        snapshots = snapshots_by_event
        products.to_h do |product|
          event = events_by_id[product.event_id.to_s]
          snapshot = snapshots[product.event_id.to_s]
          state = if event && snapshot
            OfferAvailability.call(
              product:, at:,
              capacity_snapshot: snapshot.fetch(:capacity),
              date_snapshot: snapshot.fetch(:dates)
            )
          else
            "unavailable"
          end
          [ product.id, state ]
        end
      end

      private

      attr_reader :products, :events_by_id, :at

      def snapshots_by_event
        products_by_event = products.group_by { |product| product.event_id.to_s }
        event_dates_by_event = @event_dates_by_id || event_date_rows_by_event
        events_by_id.to_h do |event_id, event|
          event_products = products_by_event.fetch(event_id, [])
          event_dates = event_dates_by_event.fetch(event_id, [])
          inventory_rows = event_products.flat_map { |product| product.inventories.to_a }
          [
            event_id,
            {
              capacity: Catalog::Inventory::Capacity::Snapshot.new(
                inventory_rows:, event_date_rows: event_dates
              ),
              dates: Events::EventDateEligibility.snapshot(event_dates:, at:)
            }
          ]
        end
      end

      def event_date_rows_by_event
        return loaded_event_dates_by_event if events_by_id.values.all? { |event| event.association(:event_dates).loaded? }

        Events::EventDate.where(event_id: events_by_id.keys)
          .order(:event_id, :starts_at, :id)
          .to_a
          .group_by { |event_date| event_date.event_id.to_s }
      end

      def loaded_event_dates_by_event
        events_by_id.to_h do |event_id, event|
          [ event_id, event.event_dates.to_a ]
        end
      end
    end
  end
end
