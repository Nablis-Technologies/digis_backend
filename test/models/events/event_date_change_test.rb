# frozen_string_literal: true

require "test_helper"

module Events
  class EventDateChangeTest < ActiveSupport::TestCase
    def setup
      @event = events_events(:ready_listing)
      @date = @event.event_dates.create!(
        starts_at: Time.zone.local(2026, 9, 1, 20),
        ends_at: Time.zone.local(2026, 9, 1, 22)
      )
      @actor = core_users(:core_admin)
    end

    def build_change(**overrides)
      Events::EventDateChange.new({
        event: @event,
        event_date: @date,
        change_type: "reschedule",
        old_start_at: @date.starts_at,
        old_end_at: @date.ends_at,
        new_start_at: @date.starts_at + 1.hour,
        new_end_at: @date.ends_at + 1.hour,
        scheduled_by: @actor
      }.merge(overrides))
    end

    test "opts out of single table inheritance" do
      assert_predicate Events::EventDateChange.inheritance_column, :blank?
      assert_not Events::EventDateChange.finder_needs_type_condition?
    end

    test "is valid with all required attributes" do
      assert build_change.valid?, build_change.errors.full_messages.inspect
    end

    test "requires an event, event_date and snapshots" do
      change = Events::EventDateChange.new
      assert_not change.valid?
      assert change.errors.key?(:event)
      assert change.errors.key?(:event_date)
      assert change.errors.key?(:new_start_at)
      assert change.errors.key?(:new_end_at)
    end

    test "belongs to its event so policies can authorize against it" do
      change = build_change
      change.save!
      assert_equal @event, change.event
    end
  end
end
