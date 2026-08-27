# frozen_string_literal: true

require "test_helper"

module Finance
  class CompleteDueEventsJobTest < ActiveJob::TestCase
    test "delegates to the bounded due-event command" do
      Finance::CompleteDueEvents.expects(:call).with { |at:| at.is_a?(Time) }
        .returns(Core::BaseService::Result.success([]))

      Finance::CompleteDueEventsJob.perform_now
    end

    test "propagates a sweep failure so the scheduler retries it" do
      failure = Finance::CompleteDueEvents::SweepFailure.new(
        completed_ids: [], failures: [ { event_id: "event-1", code: "event_completion_invalid" } ]
      )
      Finance::CompleteDueEvents.stubs(:call).raises(failure)

      assert_raises(Finance::CompleteDueEvents::SweepFailure) do
        Finance::CompleteDueEventsJob.perform_now
      end
    end

    test "is registered in the production recurring schedule" do
      schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

      assert_equal "Finance::CompleteDueEventsJob", schedule.dig("production", "complete_due_events", "class")
      assert_equal "every minute", schedule.dig("production", "complete_due_events", "schedule")
    end
  end
end
