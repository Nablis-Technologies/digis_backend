# frozen_string_literal: true

require "test_helper"

module Commercial
  module Volume
    class WindowTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:draft_concert)
        @quoted_at = Time.utc(2026, 8, 11, 10)
      end

      test "uses the complete event schedule as the event window" do
        @event.event_dates.create!(starts_at: Time.utc(2026, 8, 15, 12), ends_at: Time.utc(2026, 8, 15, 18))
        @event.event_dates.create!(starts_at: Time.utc(2026, 8, 20, 12), ends_at: Time.utc(2026, 8, 20, 22))

        window = Window.resolve(
          window_type: "event", quoted_at: @quoted_at, event: @event, event_id: @event.id
        )

        assert_equal Time.utc(2026, 8, 15, 12), window.start_at
        assert_equal Time.utc(2026, 8, 20, 22), window.end_at
        assert_equal @event.id, window.event_id
      end

      test "closes month quarter and year windows at their UTC calendar boundaries" do
        month = resolve("calendar_month")
        quarter = resolve("calendar_quarter")
        year = resolve("calendar_year")

        assert_equal [ Time.utc(2026, 8, 1), Time.utc(2026, 9, 1) ], [ month.start_at, month.end_at ]
        assert_equal [ Time.utc(2026, 7, 1), Time.utc(2026, 10, 1) ], [ quarter.start_at, quarter.end_at ]
        assert_equal [ Time.utc(2026, 1, 1), Time.utc(2027, 1, 1) ], [ year.start_at, year.end_at ]
      end

      test "uses the active assignment term for agreement-term windows" do
        assignment = Struct.new(:effective_from, :effective_until, :event_id).new(
          Time.utc(2026, 8, 1), Time.utc(2026, 9, 15), nil
        )

        window = Window.resolve(
          window_type: "agreement_term", quoted_at: @quoted_at,
          event: @event, event_id: @event.id, assignment:
        )

        assert_equal assignment.effective_from, window.start_at
        assert_equal assignment.effective_until, window.end_at
        assert_nil window.event_id
      end

      private

      def resolve(window_type)
        Window.resolve(
          window_type:, quoted_at: @quoted_at, event: @event, event_id: @event.id
        )
      end
    end
  end
end
