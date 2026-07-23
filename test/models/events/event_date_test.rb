# frozen_string_literal: true

require "test_helper"

class Events::EventDateTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing)
    @venue = events_venues(:main_hall)
  end

  test "inheritance_column is disabled (no STI)" do
    assert Events::EventDate.inheritance_column.blank?
  end

  test "ends_at must be after starts_at" do
    date = Events::EventDate.new(
      event: @event, starts_at: Time.current,
      ends_at: 1.hour.ago, status: "scheduled"
    )
    refute date.valid?
    assert date.errors[:ends_at].present?
  end

  test "doors_at must be before or at starts_at" do
    date = Events::EventDate.new(
      event: @event, starts_at: Time.current,
      doors_at: 1.hour.from_now, ends_at: 2.hours.from_now,
      status: "scheduled"
    )
    refute date.valid?
    assert date.errors[:doors_at].present?
  end

  test "status must be in the allowed set" do
    date = Events::EventDate.new(
      event: @event, starts_at: Time.current,
      ends_at: 2.hours.from_now, status: "asleep"
    )
    refute date.valid?
    assert date.errors[:status].present?
  end

  test "venue counts are nonnegative" do
    date = Events::EventDate.new(
      event: @event, venue: @venue, venue_capacity: 100,
      starts_at: Time.current, ends_at: 2.hours.from_now,
      status: "scheduled", held_venue_count: -1, issued_venue_count: 0
    )
    refute date.valid?
    assert date.errors[:held_venue_count].present?
  end

  test "held plus issued may not exceed venue_capacity" do
    date = Events::EventDate.new(
      event: @event, venue: @venue, venue_capacity: 100,
      starts_at: Time.current, ends_at: 2.hours.from_now,
      status: "scheduled", held_venue_count: 60, issued_venue_count: 50
    )
    refute date.valid?
    assert date.errors[:base].present?
  end

  test "unique source_key per event" do
    Events::EventDate.create!(
      event: @event, source_key: "recurrence-1",
      starts_at: Time.current, ends_at: 2.hours.from_now, status: "scheduled"
    )
    dup = Events::EventDate.new(
      event: @event, source_key: "recurrence-1",
      starts_at: 3.hours.from_now, ends_at: 4.hours.from_now, status: "scheduled"
    )
    refute dup.valid?
    assert dup.errors[:source_key].present?
  end
end
