# frozen_string_literal: true

require "test_helper"

module Finance
  class MatureEventFundsJobTest < ActiveJob::TestCase
    include ActiveJob::TestHelper
    include PayoutTestHelpers

    setup do
      setup_payout_context(status: "completed")
      @event.update_columns(completed_at: @now - 8.days)
      create_payout_entry(type: "sale", amount_minor: 10_000)
    end

    test "builds one idempotent payout command per event currency" do
      assert_enqueued_with(
        job: Finance::BuildPayoutsJob,
        args: [ @organization.id, "ETB", "event-maturity-#{@event.id}-ETB" ]
      ) do
        Finance::MatureEventFundsJob.perform_now(@event.id)
      end
    end
  end
end
