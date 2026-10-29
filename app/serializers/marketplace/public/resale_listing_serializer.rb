# frozen_string_literal: true

module Marketplace
  module Public
    # Buyer-facing listing projection. It joins the display context a resale
    # card needs without exposing seller, payout, payment, or scanner data.
    class ResaleListingSerializer < ActiveModel::Serializer
      attributes :id, :status, :asking_amount_minor, :currency, :resale_cutoff_at,
                 :fee_terms, :event, :product, :ticket_type, :event_dates,
                 :created_at, :updated_at

      def event
        event = object.event
        {
          id: event.id,
          slug: event.slug,
          title: event.title,
          timezone: event.timezone,
          currency: event.currency
        }
      end

      def product
        product = object.ticket.event_product
        { id: product.id, name: product.name, type: product.type }
      end

      def ticket_type
        ticket_type = object.ticket.event_product.ticket_type
        return unless ticket_type

        {
          id: ticket_type.id,
          # Ticket types are one-to-one with event products and do not have a
          # name column; the product name is their public display label.
          name: object.ticket.event_product.name,
          admissions_per_unit: ticket_type.admissions_per_unit,
          entry_validation_mode: ticket_type.entry_validation_mode
        }
      end

      def event_dates
        object.ticket.event_product.product_accesses
          .filter_map(&:event_date)
          .uniq
          .sort_by(&:starts_at)
          .map do |event_date|
            {
              id: event_date.id,
              name: event_date.name,
              starts_at: event_date.starts_at,
              ends_at: event_date.ends_at,
              status: event_date.status,
              venue: venue_summary(event_date.venue)
            }
          end
      end

      def fee_terms
        component = object.commercial_fee_component
        {
          calculation_type: component.calculation_type,
          refund_policy: component.refund_policy,
          rate_bps: component.rate_bps,
          currency: object.currency
        }.compact
      end

      private

      def venue_summary(venue)
        return unless venue

        { id: venue.id, name: venue.name, city: venue.city }
      end
    end
  end
end
