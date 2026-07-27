# frozen_string_literal: true

require "test_helper"

class Core::ProcessOutboxJobTest < ActiveJob::TestCase
  test "enqueues due unpublished rows and advances available_at" do
    due = core_outbox_events(:pending)
    Core::ProcessOutboxJob.perform_now

    assert_enqueued_with(job: Core::DispatchOutboxEventJob, args: [ due.id ])
    assert due.reload.available_at > Time.current
  end

  test "skips published rows and exhausted-retry rows" do
    published = core_outbox_events(:published)
    dead = core_outbox_events(:exhausted)

    Core::ProcessOutboxJob.perform_now

    enqueued_ids = enqueued_jobs.filter_map { |job| job[:args].first }
    assert_not_includes enqueued_ids, published.id
    assert_not_includes enqueued_ids, dead.id
  end
end
