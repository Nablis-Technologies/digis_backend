# frozen_string_literal: true

require "test_helper"

class Events::Recurrence::MaterializeTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing)
  end

  test "materializes daily occurrences within the horizon" do
    rule = Events::RecurrenceRule.create!(
      event: @event,
      rrule: "FREQ=DAILY;COUNT=3",
      timezone: "America/New_York",
      dtstart_local: Time.zone.parse("2026-08-01 19:00:00"),
      duration_seconds: 3 * 3600,
      generated_until: Time.zone.parse("2026-08-31 23:59:59")
    )

    result = Events::Recurrence::Materialize.call(rule:)

    assert result.success?, result.error.inspect
    dates = @event.event_dates.where("source_key LIKE ?", "recurrence-#{rule.id}-%")
    assert_equal 3, dates.count
    assert dates.all? { |d| d.source_key.present? }
    assert_equal "scheduled", dates.first.status
  end

  test "assigns a unique source_key per generated date" do
    rule = Events::RecurrenceRule.create!(
      event: @event,
      rrule: "FREQ=DAILY;COUNT=5",
      timezone: "America/New_York",
      dtstart_local: Time.zone.parse("2026-08-01 19:00:00"),
      duration_seconds: 3 * 3600,
      generated_until: Time.zone.parse("2026-08-31 23:59:59")
    )

    Events::Recurrence::Materialize.call(rule:)

    keys = @event.event_dates.where("source_key LIKE ?", "recurrence-#{rule.id}-%").pluck(:source_key)
    assert_equal keys.uniq.count, keys.count
  end

  test "does not recalculate already-edited dates" do
    rule = Events::RecurrenceRule.create!(
      event: @event,
      rrule: "FREQ=DAILY;COUNT=3",
      timezone: "America/New_York",
      dtstart_local: Time.zone.parse("2026-08-01 19:00:00"),
      duration_seconds: 3 * 3600,
      generated_until: Time.zone.parse("2026-08-31 23:59:59")
    )

    Events::Recurrence::Materialize.call(rule:)
    first_run = @event.event_dates.where("source_key LIKE ?", "recurrence-#{rule.id}-%")
                                .pluck(:starts_at, :ends_at)

    # Edit one generated date in place (simulating an organizer edit).
    # Shift both timestamps by the same offset so the date stays valid
    # (ends_at > starts_at) and the shifted start no longer collides with
    # another daily occurrence's 19:00 start time.
    edited = @event.event_dates.where("source_key LIKE ?", "recurrence-#{rule.id}-%").first
    edited.update!(
      starts_at: edited.starts_at + 1.hour,
      ends_at: edited.ends_at + 1.hour
    )

    Events::Recurrence::Materialize.call(rule:)
    second_run = @event.event_dates.where("source_key LIKE ?", "recurrence-#{rule.id}-%")
                                  .pluck(:starts_at, :ends_at)

    # Count unchanged (the edited row must survive, not be replaced)
    assert_equal first_run.count, second_run.count
  end

  test "excludes EXDATE occurrences" do
    rule = Events::RecurrenceRule.create!(
      event: @event,
      rrule: "FREQ=DAILY;COUNT=5",
      timezone: "America/New_York",
      dtstart_local: Time.zone.parse("2026-08-01 19:00:00"),
      duration_seconds: 3 * 3600,
      generated_until: Time.zone.parse("2026-08-31 23:59:59"),
      exdates: [
        "2026-08-02T19:00:00-04:00",
        "2026-08-04T19:00:00-04:00"
      ]
    )

    result = Events::Recurrence::Materialize.call(rule:)

    assert result.success?, result.error.inspect
    dates = @event.event_dates.where("source_key LIKE ?", "recurrence-#{rule.id}-%")
    assert_equal 3, dates.count
    starts = dates.pluck(:starts_at).map(&:to_i).sort
    # Remaining occurrences: Aug 1, Aug 3, Aug 5 (in NY local time)
    expected = [
      Time.new(2026, 8, 1, 19, 0, 0, "-04:00").to_i,
      Time.new(2026, 8, 3, 19, 0, 0, "-04:00").to_i,
      Time.new(2026, 8, 5, 19, 0, 0, "-04:00").to_i
    ]
    assert_equal expected.sort, starts
  end

  test "includes RDATE extra occurrences" do
    rule = Events::RecurrenceRule.create!(
      event: @event,
      rrule: "FREQ=DAILY;COUNT=2",
      timezone: "America/New_York",
      dtstart_local: Time.zone.parse("2026-08-01 19:00:00"),
      duration_seconds: 3 * 3600,
      generated_until: Time.zone.parse("2026-08-31 23:59:59"),
      rdates: [
        "2026-08-10T19:00:00-04:00"
      ]
    )

    result = Events::Recurrence::Materialize.call(rule:)

    assert result.success?, result.error.inspect
    dates = @event.event_dates.where("source_key LIKE ?", "recurrence-#{rule.id}-%")
    assert_equal 3, dates.count
    assert dates.pluck(:starts_at).map(&:to_i).include?(
      Time.new(2026, 8, 10, 19, 0, 0, "-04:00").to_i
    )
  end
end
