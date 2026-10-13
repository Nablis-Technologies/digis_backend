# frozen_string_literal: true

module Marketing
  module FeaturedPlacements
    # Produces an authoritative, non-reserving price and availability quote.
    class Quote < Core::BaseService
      MINIMUM_LEAD_TIME = 60.minutes
      MAXIMUM_START_HORIZON = 14.days
      SECONDS_PER_DAY = 86_400

      Snapshot = Data.define(
        :offer_id, :offer_code, :offer_version, :surface, :starts_at, :ends_at, :duration_seconds,
        :daily_rate_minor, :amount_minor, :currency, :terms_version, :capacity_available,
        :capacity_limit, :next_available_at
      )

      def initialize(event:, offer:, starts_at:, at: Time.current)
        @event = event
        @offer_id = offer.respond_to?(:id) ? offer.id : offer
        @raw_starts_at = starts_at
        @at = at.to_time.utc
      end

      def call
        return failure(error(:feature_disabled, status: :service_unavailable)) unless
          Rails.application.config.x.marketing_featured_placements_enabled == true

        offer = PlacementOffer.active_at(at).find_by(id: offer_id)
        return failure(error(:offer_unavailable)) unless offer

        eligibility = EventEligibility.call(event:, at:)
        return failure(eligibility.error) if eligibility.failure?

        ends_at = eligibility.value.to_time.utc
        selected_start = normalize_start_time(raw_starts_at)
        validation = validate_window(selected_start, ends_at, offer)
        return failure(validation) if validation

        capacity_result = Capacity.call(
          event_id: event.id, surface: offer.surface, starts_at: selected_start, ends_at:, at:
        )
        return failure(capacity_result.error) if capacity_result.failure?

        capacity = capacity_result.value
        duration = (ends_at - selected_start).to_i
        success(Snapshot.new(
          offer.id, offer.code, offer.version, offer.surface, selected_start, ends_at, duration,
          offer.daily_rate_minor, price_for(offer.daily_rate_minor, duration), offer.currency,
          offer.terms_version, capacity.available, capacity.limit, capacity.next_available_at
        ))
      rescue ArgumentError, TypeError
        failure(error(:invalid_schedule))
      end

      private

      attr_reader :event, :offer_id, :raw_starts_at, :at

      def normalize_start_time(value)
        parsed = value.respond_to?(:to_time) ? value.to_time : Time.zone.parse(value.to_s)
        raise ArgumentError if parsed.blank?

        Time.at(parsed.to_i).utc
      end

      def validate_window(starts_at, ends_at, offer)
        duration = (ends_at - starts_at).to_i
        return error(:invalid_schedule) unless starts_at >= at + MINIMUM_LEAD_TIME
        return error(:invalid_schedule) unless starts_at < ends_at
        return error(:invalid_schedule) unless starts_at >= ends_at - MAXIMUM_START_HORIZON
        return error(:invalid_schedule) unless duration.between?(offer.minimum_duration_seconds, offer.maximum_duration_seconds)

        nil
      end

      def price_for(daily_rate_minor, duration_seconds)
        (daily_rate_minor * duration_seconds + SECONDS_PER_DAY - 1) / SECONDS_PER_DAY
      end

      def error(key, status: :unprocessable_entity)
        Core::BusinessError.new(
          I18n.t("marketing.featured_placements.errors.#{key}"), code: key.to_s, status:
        )
      end
    end
  end
end
