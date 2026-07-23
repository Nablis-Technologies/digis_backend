# frozen_string_literal: true

require "rrule"

module Events
  module Recurrence
    # Materializes recurrence rules into concrete event_dates rows using Square's
    # `rrule` gem (RFC 5545 parsing, DST-aware expansion, EXDATE via the
    # `exdate:` option). RDATE (extra pinned dates) are appended after expansion
    # since the gem has no native RDATE option.
    #
    # Idempotent: an already-materialized date (matched by `source_key`) is never
    # recalculated, so an organizer's edited or sold date is preserved when the
    # rule is re-run or changed (per spec 6.8).
    class Materialize < Core::BaseService
      MAX_OCCURRENCES = 3650

      def initialize(rule:)
        @rule = rule
        @event = rule.event
        @timezone = rule.timezone
        @duration = rule.duration_seconds
        @dtstart = build_dtstart
      end

      def call
        rrule = RRule::Rule.new(
          @rule.rrule,
          dtstart: @dtstart,
          tzid: @timezone,
          exdate: parse_times(@rule.exdates)
        )

        horizon = @rule.generated_until || (@dtstart + MAX_OCCURRENCES.days)
        occurrences = rrule.between(@dtstart, horizon)
        parse_times(@rule.rdates).each { |time| occurrences << time }

        existing = @event.event_dates
                       .where(source_key: occurrence_keys(occurrences))
                       .index_by(&:source_key)

        occurrences.each do |starts_at|
          source_key = source_key_for(starts_at)
          next if existing.key?(source_key)

          @event.event_dates.create!(
            source_key: source_key,
            starts_at: starts_at,
            ends_at: starts_at + @duration,
            status: "scheduled"
          )
        end

        success
      rescue ArgumentError, TZInfo::InvalidTimezoneIdentifier => e
        failure Core::BusinessError.new(
          I18n.t("events.recurrence.materialize.errors.invalid"),
          code: "invalid",
          status: :unprocessable_entity,
          errors: { rrule: [ e.message ] }
        )
      end

      private

      def build_dtstart
        zone = ActiveSupport::TimeZone[@timezone]
        raise ArgumentError, "invalid timezone: #{@timezone}" unless zone

        local = zone.local(
          @rule.dtstart_local.year, @rule.dtstart_local.month, @rule.dtstart_local.day,
          @rule.dtstart_local.hour, @rule.dtstart_local.min, @rule.dtstart_local.sec
        )
        Time.new(
          local.year, local.month, local.day,
          local.hour, local.min, local.sec, local.formatted_offset
        )
      end

      def parse_times(values)
        Array(values).map { |value| value.is_a?(Time) ? value : Time.iso8601(value.to_s) }
      end

      def source_key_for(time)
        "recurrence-#{@rule.id}-#{time.to_i}"
      end

      def occurrence_keys(occurrences)
        occurrences.map { |time| source_key_for(time) }
      end
    end
  end
end
