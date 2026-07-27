# frozen_string_literal: true

require "test_helper"

module Events
  class EventCancellationTest < ActiveSupport::TestCase
    def setup
      @event = events_events(:ready_listing)
      @actor = core_users(:core_admin)
    end

    def build_cancellation(**overrides)
      Events::EventCancellation.new({
        event: @event,
        initiated_by: @actor,
        status: "initiated",
        cancelled_at: Time.current,
        idempotency_key: "cancel-#{SecureRandom.uuid}"
      }.merge(overrides))
    end

    test "opts out of single table inheritance" do
      assert_predicate Events::EventCancellation.inheritance_column, :blank?
      assert_not Events::EventCancellation.finder_needs_type_condition?
    end

    test "is valid with all required attributes" do
      cancellation = build_cancellation
      assert cancellation.valid?, cancellation.errors.full_messages.inspect
    end

    test "requires an event and an initiator" do
      cancellation = Events::EventCancellation.new
      assert_not cancellation.valid?
      assert cancellation.errors.key?(:event)
      assert cancellation.errors.key?(:initiated_by)
    end

    test "enforces at most one cancellation per event at the database level" do
      build_cancellation.save!

      assert_raises(ActiveRecord::RecordNotUnique) do
        Events::EventCancellation.new(
          event: @event,
          initiated_by: @actor,
          status: "initiated",
          cancelled_at: Time.current,
          idempotency_key: "another-key"
        ).save!(validate: false)
      end
    end

    test "belongs to its event so policies can authorize against it" do
      cancellation = build_cancellation
      cancellation.save!
      assert_equal @event, cancellation.event
    end
  end
end
