# frozen_string_literal: true

require "test_helper"

class Events::EventParticipantTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing)
    @date = @event.event_dates.create!(
      starts_at: 1.day.from_now, ends_at: 1.day.from_now + 2.hours, status: "scheduled"
    )
  end

  test "inheritance_column is disabled (no STI)" do
    assert Events::EventParticipant.inheritance_column.blank?
  end

  test "name is required" do
    participant = Events::EventParticipant.new(event: @event, type: "performer")
    refute participant.valid?
    assert participant.errors[:name].present?
  end

  test "type must be in the allowed set" do
    participant = Events::EventParticipant.new(event: @event, name: "DJ X", type: "wizard")
    refute participant.valid?
    assert participant.errors[:type].present?
  end

  test "display_order defaults to zero" do
    participant = Events::EventParticipant.create!(
      event: @event, name: "DJ X", type: "performer"
    )
    assert_equal 0, participant.display_order
  end

  test "event date must belong to the same event" do
    other = events_events(:draft_concert)
    other_date = other.event_dates.create!(
      starts_at: 2.days.from_now, ends_at: 2.days.from_now + 2.hours, status: "scheduled"
    )
    participant = Events::EventParticipant.new(
      event: @event, name: "DJ X", type: "performer", event_date_id: other_date.id
    )
    refute participant.valid?
    assert participant.errors[:event_date].present?
  end

  test "links to a date in the same event" do
    participant = Events::EventParticipant.new(
      event: @event, name: "DJ X", type: "performer", event_date_id: @date.id
    )
    assert participant.valid?
  end
end
