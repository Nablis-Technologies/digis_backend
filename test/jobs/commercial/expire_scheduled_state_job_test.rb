# frozen_string_literal: true

require "test_helper"

module Commercial
  class ExpireScheduledStateJobTest < ActiveJob::TestCase
    include Commercial::GovernanceTestHelpers

    test "expires due scheduled versions idempotently" do
      version = create_simulatable_version(
        code: "task12_expiry",
        attributes: { effective_from: 2.days.ago, effective_until: 1.hour.ago }
      )
      version.update!(status: "scheduled")

      first = Commercial::ExpireScheduledStateJob.perform_now(at: Time.current)
      second = Commercial::ExpireScheduledStateJob.perform_now(at: Time.current)

      assert_equal 1, first
      assert_equal 0, second
      assert_equal "expired", version.reload.status
      assert_equal 1, Core::OutboxEvent.where(event_type: "commercial.version.expired").count
    end
  end
end
