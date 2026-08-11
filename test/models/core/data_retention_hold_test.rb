# frozen_string_literal: true

require "test_helper"

module Core
  class DataRetentionHoldTest < ActiveSupport::TestCase
    test "requires exactly one retention scope" do
      hold = DataRetentionHold.new(
        reason_code: "legal_hold",
        placed_by: core_users(:super_admin),
        starts_at: Time.current,
        idempotency_key: "hold-without-scope"
      )

      assert_not hold.valid?
      assert hold.errors.key?(:base)
    end

    test "active holds honor their release window" do
      hold = DataRetentionHold.new(
        event: events_events(:ready_listing),
        category: "registration_free_text",
        reason_code: "legal_hold",
        placed_by: core_users(:super_admin),
        starts_at: 1.hour.ago,
        expires_at: 1.hour.from_now,
        idempotency_key: "active-hold"
      )

      assert hold.valid?
      assert_predicate hold, :active?

      hold.released_by = core_users(:super_admin)
      hold.released_at = Time.current

      assert hold.valid?
      assert_not hold.active?
    end
  end
end
