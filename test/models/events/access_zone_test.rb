# frozen_string_literal: true

require "test_helper"

class Events::AccessZoneTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing)
    @date = @event.event_dates.create!(
      starts_at: 1.day.from_now, ends_at: 1.day.from_now + 2.hours, status: "scheduled"
    )
  end

  test "inheritance_column is disabled (no STI)" do
    assert Events::AccessZone.inheritance_column.blank?
  end

  test "name and code are required" do
    zone = Events::AccessZone.new(event: @event, type: "venue")
    refute zone.valid?
    assert zone.errors[:name].present?
    assert zone.errors[:code].present?
  end

  test "type must be venue or parking" do
    zone = Events::AccessZone.new(event: @event, name: "Main Gate", code: "GATE-A", type: "rocket")
    refute zone.valid?
    assert zone.errors[:type].present?
  end

  test "code is unique per event" do
    Events::AccessZone.create!(event: @event, name: "Main Gate", code: "GATE-A", type: "venue")
    dup = Events::AccessZone.new(event: @event, name: "Other", code: "GATE-A", type: "venue")
    refute dup.valid?
    assert dup.errors[:code].present?
  end

  test "event date must belong to the same event" do
    other = events_events(:draft_concert)
    other_date = other.event_dates.create!(
      starts_at: 2.days.from_now, ends_at: 2.days.from_now + 2.hours, status: "scheduled"
    )
    zone = Events::AccessZone.new(
      event: @event, name: "Main Gate", code: "GATE-A", type: "venue", event_date_id: other_date.id
    )
    refute zone.valid?
    assert zone.errors[:event_date].present?
  end

  test "valid zone is accepted" do
    zone = Events::AccessZone.new(
      event: @event, name: "Main Gate", code: "GATE-A", type: "venue"
    )
    assert zone.valid?
  end
end
