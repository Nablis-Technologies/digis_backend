# frozen_string_literal: true

module Commercial
  module Volume
    # Resolves one deterministic measurement window for both quote evidence and
    # accepted-order usage. The exact bounds are part of the dimension, so a
    # calendar boundary or agreement revision can never merge old activity into
    # a new prospective tier accidentally.
    class Window
      Value = Data.define(:window_type, :event_id, :start_at, :end_at, :currency)

      WINDOW_TYPES = Commercial::FeeTier::WINDOW_TYPES

      def self.resolve(window_type:, quoted_at:, event: nil, event_id: nil, assignment: nil,
        version: nil, currency: nil)
        new(
          window_type:, quoted_at:, event:, event_id:, assignment:, version:, currency:
        ).resolve
      end

      def initialize(window_type:, quoted_at:, event:, event_id:, assignment:, version:, currency:)
        @window_type = window_type.to_s
        @quoted_at = quoted_at.to_time.utc
        @event = event
        @event_id = event_id || event&.id
        @assignment = assignment
        @version = version
        @currency = currency.to_s.strip.upcase.presence
      end

      def resolve
        raise ArgumentError, I18n.t("commercial.volume.errors.invalid_window") unless WINDOW_TYPES.include?(@window_type)

        start_at, end_at = bounds
        raise ArgumentError, I18n.t("commercial.volume.errors.window_bounds") if end_at && end_at <= start_at

        Value.new(
          window_type: @window_type,
          event_id: scoped_event_id,
          start_at: start_at.utc.freeze,
          end_at: end_at&.utc&.freeze,
          currency: @currency&.freeze
        ).freeze
      end

      private

      def bounds
        case @window_type
        when "event"
          event_bounds
        when "calendar_month"
          calendar_bounds(months: 1)
        when "calendar_quarter"
          month = ((@quoted_at.month - 1) / 3) * 3 + 1
          start_at = Time.utc(@quoted_at.year, month, 1)
          [ start_at, start_at.advance(months: 3) ]
        when "calendar_year"
          start_at = Time.utc(@quoted_at.year, 1, 1)
          [ start_at, start_at.advance(years: 1) ]
        when "agreement_term"
          [ agreement_start, agreement_end ]
        end
      end

      def calendar_bounds(months:)
        start_at = Time.utc(@quoted_at.year, @quoted_at.month, 1)
        [ start_at, start_at.advance(months:) ]
      end

      def event_bounds
        dates = @event&.event_dates&.to_a || []
        return [ @event&.created_at&.utc || @quoted_at, nil ] if dates.empty?

        [ dates.map(&:starts_at).compact.min.utc, dates.map(&:ends_at).compact.max&.utc ]
      end

      def agreement_start
        @assignment&.effective_from&.utc || @version&.effective_from&.utc || @quoted_at
      end

      def agreement_end
        @assignment&.effective_until&.utc || @version&.effective_until&.utc
      end

      def scoped_event_id
        return @event_id if @window_type == "event"

        @assignment&.event_id
      end
    end
  end
end
