# frozen_string_literal: true

require "test_helper"

module Reconciliation
  class SupervisorJobTest < ActiveJob::TestCase
    test "enqueues every reconciliation domain exactly once" do
      expected = Reconciliation::SupervisorJob::JOBS

      assert_enqueued_jobs expected.length do
        Reconciliation::SupervisorJob.perform_now
      end

      assert_equal expected, enqueued_jobs.map { |job| job[:job] }
    end

    test "supports separate fast and slow operating cadences" do
      assert_enqueued_jobs 3 do
        Reconciliation::SupervisorJob.perform_now("fast")
      end
      assert_equal Reconciliation::SupervisorJob::FAST_JOBS,
        enqueued_jobs.map { |job| job[:job] }

      clear_enqueued_jobs

      assert_enqueued_jobs 3 do
        Reconciliation::SupervisorJob.perform_now("slow")
      end
      assert_equal Reconciliation::SupervisorJob::SLOW_JOBS,
        enqueued_jobs.map { |job| job[:job] }
    end

    test "does not mutate domain records while supervising" do
      before = Core::OutboxEvent.order(:id).pluck(:id, :published_at, :attempts)

      Reconciliation::SupervisorJob.perform_now

      assert_equal before, Core::OutboxEvent.order(:id).pluck(:id, :published_at, :attempts)
    end
  end
end
