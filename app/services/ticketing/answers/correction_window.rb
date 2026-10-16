# frozen_string_literal: true

module Ticketing
  module Answers
    # Resolves the shared attendee answer-correction deadline for a registration.
    # A nil cutoff means no scheduled start currently closes attendee edits.
    class CorrectionWindow
      def self.call(registration:)
        cutoffs_for(registrations: [ registration ]).fetch(registration.id)
      end

      def self.cutoffs_for(registrations:)
        new(registrations:).call
      end

      def call
        return {} if registrations.empty?

        starts_by_registration = selected_date_starts
        registrations_without_selected_date = registrations.reject(&:selected_event_date_id)
        ticket_type_details = ticket_type_details_for(registrations)
        product_accesses = product_access_summary(registrations_without_selected_date, ticket_type_details)
        registrations_without_accesses = registrations_without_selected_date.reject do |registration|
          product_accesses.dig(registration.ticket_type_id, 0).to_i.positive?
        end
        fallback_starts = event_date_starts(registrations_without_accesses)

        registrations.to_h do |registration|
          starts_at = starts_by_registration[registration.selected_event_date_id]
          unless registration.selected_event_date_id
            access_count, access_start = product_accesses[registration.ticket_type_id]
            starts_at = access_count.positive? ? access_start : fallback_starts[registration.event_id]
          end
          cutoff_seconds = ticket_type_details.dig(registration.ticket_type_id, :cutoff_seconds)
          [ registration.id, cutoff_for(starts_at, cutoff_seconds) ]
        end
      end

      private

      attr_reader :registrations

      def initialize(registrations:)
        @registrations = Array(registrations).uniq(&:id)
      end

      def selected_date_starts
        selected_ids = registrations.filter_map(&:selected_event_date_id).uniq
        return {} if selected_ids.empty?

        Events::EventDate.where(id: selected_ids).pluck(:id, :starts_at).to_h
      end

      def ticket_type_details_for(registration_rows)
        ticket_type_ids = registration_rows.map(&:ticket_type_id).uniq
        return {} if ticket_type_ids.empty?

        Ticketing::TicketType.where(id: ticket_type_ids)
          .pluck(:id, :event_product_id, :transfer_cutoff_seconds_before_start)
          .to_h do |ticket_type_id, product_id, cutoff_seconds|
            [ ticket_type_id, { event_product_id: product_id, cutoff_seconds: } ]
          end
      end

      def product_access_summary(registration_rows, ticket_type_details)
        event_product_ids = registration_rows.filter_map do |registration|
          ticket_type_details.dig(registration.ticket_type_id, :event_product_id)
        end.uniq
        return {} if event_product_ids.empty?

        product_accesses = Catalog::ProductAccess.where(event_product_id: event_product_ids)
          .left_joins(:event_date)
          .group(:event_product_id)
          .pluck(
            :event_product_id,
            Arel.sql("COUNT(catalog_product_accesses.id)"),
            Arel.sql("MIN(events_event_dates.starts_at) FILTER (WHERE events_event_dates.status <> 'cancelled')")
          )
          .to_h { |product_id, count, starts_at| [ product_id, [ count, starts_at ] ] }

        ticket_type_details.to_h do |ticket_type_id, details|
          [ ticket_type_id, product_accesses.fetch(details.fetch(:event_product_id), [ 0, nil ]) ]
        end
      end

      def event_date_starts(registration_rows)
        event_ids = registration_rows.map(&:event_id).uniq
        return {} if event_ids.empty?

        Events::EventDate.where(event_id: event_ids)
          .where.not(status: "cancelled")
          .group(:event_id)
          .minimum(:starts_at)
      end

      def cutoff_for(starts_at, cutoff_seconds)
        return unless starts_at
        return unless cutoff_seconds

        starts_at - cutoff_seconds.seconds
      end
    end
  end
end
