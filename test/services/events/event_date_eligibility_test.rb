# frozen_string_literal: true

require "test_helper"

module Events
  class EventDateEligibilityTest < ActiveSupport::TestCase
    DateRow = Struct.new(:id, :status, :starts_at)

    test "fixed selections require every granted date to remain scheduled and future" do
      at = Time.utc(2026, 9, 1, 12)
      past = DateRow.new("019e5f69-dfff-7000-8000-000000000001", "scheduled", at - 1.hour)
      future = DateRow.new("019e5f69-dfff-7000-8000-000000000002", "scheduled", at + 1.hour)
      snapshot = Events::EventDateEligibility.snapshot(event_dates: [ past, future ], at:)

      refute snapshot.eligible?([ past.id, future.id ])
      assert snapshot.eligible?([ future.id ])
    end

    test "an empty selection requires a future date only when the event has dates" do
      at = Time.utc(2026, 9, 1, 12)
      past = DateRow.new("019e5f69-dfff-7000-8000-000000000001", "completed", at - 1.hour)

      assert Events::EventDateEligibility.snapshot(event_dates: [], at:).eligible?([])
      refute Events::EventDateEligibility.snapshot(event_dates: [ past ], at:).eligible?([])
    end

    test "a selected date must be an existing event date UUID" do
      at = Time.utc(2026, 9, 1, 12)
      future = DateRow.new("019e5f69-dfff-7000-8000-000000000002", "scheduled", at + 1.hour)
      snapshot = Events::EventDateEligibility.snapshot(event_dates: [ future ], at:)

      refute snapshot.eligible?([ "not-a-uuid" ])
      refute snapshot.eligible?([ "019e5f69-dfff-7000-8000-000000000099" ])
    end
  end
end
