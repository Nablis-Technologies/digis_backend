# frozen_string_literal: true

require "test_helper"

class Events::EventStreamTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing)
    @date = @event.event_dates.create!(
      starts_at: 1.day.from_now, ends_at: 1.day.from_now + 2.hours, status: "scheduled"
    )
  end

  test "inheritance_column is disabled (no STI)" do
    assert Events::EventStream.inheritance_column.blank?
  end

  test "provider is required" do
    stream = Events::EventStream.new(
      event_date: @date, access_protection: "public",
      live_from: 1.day.from_now, live_until: 2.days.from_now
    )
    refute stream.valid?
    assert stream.errors[:provider].present?
  end

  test "access_protection must be in the allowed set" do
    stream = Events::EventStream.new(
      event_date: @date, provider: "youtube", access_protection: "secret",
      live_from: 1.day.from_now, live_until: 2.days.from_now
    )
    refute stream.valid?
    assert stream.errors[:access_protection].present?
  end

  test "live_from and live_until are required" do
    stream = Events::EventStream.new(
      event_date: @date, provider: "youtube", access_protection: "public"
    )
    refute stream.valid?
    assert stream.errors[:live_from].present?
    assert stream.errors[:live_until].present?
  end

  test "replay_available_until is required when replay is enabled" do
    stream = Events::EventStream.new(
      event_date: @date, provider: "youtube", access_protection: "public",
      live_from: 1.day.from_now, live_until: 2.days.from_now,
      replay_enabled: true
    )
    refute stream.valid?
    assert stream.errors[:replay_available_until].present?
  end

  test "live status requires a provider playback id" do
    stream = Events::EventStream.new(
      event_date: @date, provider: "youtube", access_protection: "public",
      live_from: 1.day.from_now, live_until: 2.days.from_now, status: "live"
    )
    refute stream.valid?
    assert stream.errors[:provider_playback_id].present?
  end

  test "valid stream is accepted" do
    stream = Events::EventStream.new(
      event_date: @date, provider: "youtube", access_protection: "public",
      live_from: 1.day.from_now, live_until: 2.days.from_now,
      status: "scheduled"
    )
    assert stream.valid?
  end
end
