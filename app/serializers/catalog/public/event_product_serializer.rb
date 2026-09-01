# frozen_string_literal: true

module Catalog
  module Public
    # Attendee-safe product fields for published public events. Price options
    # and availability are projections; quote/reservation remains authoritative.
    class EventProductSerializer < ActiveModel::Serializer
      attributes :id, :event_id, :name, :description, :type,
                 :allow_custom_price, :sales_start_at, :sales_end_at,
                 :min_per_order, :max_per_order,
                 :schedule_change_refund_policy, :sort_order, :price_options, :available

      belongs_to :ticket_type, serializer: Catalog::Public::TicketTypeSerializer, optional: true

      def price_options
        object.prices.to_a
          .select { |price| active_price?(price) }
          .sort_by { |price| [ price.currency, price.amount_minor, price.active_from ] }
          .map { |price| Catalog::Public::ProductPriceSerializer.new(price).attributes }
      end

      def available
        instance_options.fetch(:availability, {}).fetch(object.id, false)
      end

      private

      def active_price?(price)
        price.active_from <= evaluation_time &&
          (price.active_to.blank? || price.active_to > evaluation_time)
      end

      def evaluation_time
        instance_options.fetch(:at, Time.current)
      end
    end
  end
end
