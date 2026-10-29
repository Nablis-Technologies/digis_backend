# frozen_string_literal: true

module Marketing
  module FeaturedPlacements
    # Resolves the event's public doors time and verifies current public sale.
    class EventEligibility < Core::BaseService
      def self.eligible_event_ids(events:, at: Time.current)
        candidates = Array(events).select do |event|
          event.status == "published" && event.visibility == "public"
        end
        return [] if candidates.empty?

        starts_by_event = Events::EventDate.where(event_id: candidates.map(&:id), status: "scheduled")
          .group(:event_id).minimum(:starts_at)
        upcoming = candidates.select do |event|
          starts_at = starts_by_event[event.id]
          starts_at && starts_at > at
        end
        return [] if upcoming.empty?

        availability = Catalog::Public::EventAvailabilitySummary.call(events: upcoming, at:)
        upcoming.select do |event|
          availability.dig(event.id, :ticket_availability) == "available"
        end.map(&:id)
      end

      def initialize(event:, at: Time.current)
        @event = event
        @at = at.to_time.utc
      end

      def call
        public_event = Events::Event.publicly_visible.includes(:event_dates).find_by(id: event.id)
        return failure(error(:event_ineligible)) unless public_event

        doors_at = Events::EventDate.where(event_id: public_event.id, status: "scheduled").minimum(:starts_at)
        return failure(error(:event_schedule_unavailable)) unless doors_at && doors_at > at

        summary = Catalog::Public::EventAvailabilitySummary.call(events: [ public_event ], at:)
        return failure(error(:event_registration_closed)) unless summary.dig(public_event.id, :ticket_availability) == "available"

        success(doors_at)
      rescue ActiveRecord::RecordNotFound
        failure(error(:event_ineligible))
      end

      private

      attr_reader :event, :at

      def error(key)
        Core::BusinessError.new(
          I18n.t("marketing.featured_placements.errors.#{key}"),
          code: key.to_s,
          status: :unprocessable_entity
        )
      end
    end
  end
end
