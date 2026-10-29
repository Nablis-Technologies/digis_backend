# frozen_string_literal: true

require "set"
require "time"

module Events
  module Public
    # Supplies small date previews for event cards/details and a relation for
    # the independently paginated public schedule endpoint.
    class DatesQuery < Core::BaseService
      PREVIEW_LIMIT = 7
      PREVIEW_STATUSES = %w[scheduled postponed cancelled].freeze
      CARD_STATUSES = %w[scheduled postponed].freeze
      InvalidFilter = Class.new(StandardError)

      Preview = Data.define(:dates_by_event_id, :recurring_event_ids)
      Result = Data.define(:scope)

      def self.preview_for(events:, at:, limit: PREVIEW_LIMIT, statuses: PREVIEW_STATUSES)
        event_ids = Array(events).map(&:id)
        return Preview.new({}, Set.new) if event_ids.empty?

        bounded_limit = [ [ limit.to_i, 1 ].max, PREVIEW_LIMIT ].min
        ranked_dates = Events::EventDate.where(event_id: event_ids)
          .where(status: statuses)
          .where("events_event_dates.ends_at > ?", at)
          .select(<<~SQL.squish)
            events_event_dates.id,
            events_event_dates.event_id,
            ROW_NUMBER() OVER (
              PARTITION BY events_event_dates.event_id
              ORDER BY events_event_dates.starts_at, events_event_dates.id
            ) AS preview_rank
          SQL
        date_ids = Events::EventDate.from(ranked_dates, :ranked_event_dates)
          .where("ranked_event_dates.preview_rank <= ?", bounded_limit)
          .select("ranked_event_dates.id")
        dates = Events::EventDate.where(id: date_ids).includes(:venue).order(:event_id, :starts_at, :id).to_a
        recurring_event_ids = Events::RecurrenceRule.where(event_id: event_ids).pluck(:event_id).to_set

        Preview.new(dates.group_by(&:event_id), recurring_event_ids)
      end

      def initialize(event:, parameters:, at: Time.current)
        @event = event
        @parameters = parameters
        @at = at.to_time.utc
      end

      def call
        source = @parameters.respond_to?(:to_unsafe_h) ? @parameters.to_unsafe_h : @parameters.to_h
        source = source.stringify_keys
        from = timestamp(source["from"]) || at
        to = timestamp(source["to"])
        raise InvalidFilter if to && from >= to

        scope = event.event_dates.where("events_event_dates.starts_at >= ?", from)
        scope = scope.where("events_event_dates.starts_at < ?", to) if to
        success(Result.new(scope))
      rescue InvalidFilter
        failure(invalid_filter)
      end

      private

      attr_reader :event, :at

      def timestamp(value)
        return if value.nil? || value == ""
        raise InvalidFilter unless value.is_a?(String)

        Time.iso8601(value).utc
      rescue ArgumentError
        raise InvalidFilter
      end

      def invalid_filter
        Core::BusinessError.new(
          I18n.t("event.errors.invalid_public_event_filter"),
          code: "invalid_public_event_filter", status: :unprocessable_entity
        )
      end
    end
  end
end
