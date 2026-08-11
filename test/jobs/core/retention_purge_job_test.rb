# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

module Core
  class RetentionPurgeJobTest < ActiveJob::TestCase
    include ActiveJob::TestHelper

    test "runs the bounded retention erasure command" do
      result = Core::BaseService::Result.success(
        answers: 1, revisions: 0, consents: 0, skipped: 0, errors: 0, processed: 1
      )
      Core::Retention::EraseEligibleBatch
        .expects(:call)
        .with(limit: Core::RetentionPurgeJob::BATCH_SIZE)
        .returns(result)

      assert_equal result.value, Core::RetentionPurgeJob.perform_now
    end

    test "continues with another bounded batch when the first batch is full" do
      first = Core::BaseService::Result.success({ answers: 100, revisions: 0, consents: 0, processed: 100 })
      second = Core::BaseService::Result.success({ answers: 1, revisions: 0, consents: 0, processed: 1 })
      Core::Retention::EraseEligibleBatch
        .expects(:call)
        .with(limit: Core::RetentionPurgeJob::BATCH_SIZE)
        .twice
        .returns(first, second)

      result = Core::RetentionPurgeJob.perform_now

      assert_equal 101, result[:answers]
    end

    test "clamps an oversized requested batch before invoking the service" do
      result = Core::BaseService::Result.success(
        answers: 1, revisions: 0, consents: 0, skipped: 0, errors: 0, processed: 1
      )
      Core::Retention::EraseEligibleBatch
        .expects(:call)
        .with(limit: Core::Retention::EraseEligibleBatch::MAX_BATCH_SIZE)
        .returns(result)

      result = Core::RetentionPurgeJob.perform_now(200)

      assert_equal 1, result[:answers]
    end

    test "production recurring schedule invokes the purge job" do
      schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
        .fetch("production").fetch("purge_retention_payloads")

      assert_equal "Core::RetentionPurgeJob", schedule.fetch("class")
      assert_equal "every hour at minute 5", schedule.fetch("schedule")
    end
  end
end
