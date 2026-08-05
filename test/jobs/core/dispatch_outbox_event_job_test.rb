# frozen_string_literal: true

require "test_helper"

class Core::DispatchOutboxEventJobTest < ActiveJob::TestCase
  setup do
    # Preserve the real handlers registered by initializers; this test mutates
    # the global outbox_handlers hash and must restore it so later tests in
    # the same worker are not polluted.
    @original_outbox_handlers = Rails.application.config.x.outbox_handlers
  end

  teardown do
    Rails.application.config.x.outbox_handlers = @original_outbox_handlers
  end

  test "marks the event published only after the handler succeeds" do
    event = core_outbox_events(:pending)
    handler = ->(outbox_event) { assert_equal event.id, outbox_event.id }

    Rails.application.config.x.outbox_handlers = { event.event_type => handler }
    perform_enqueued_jobs { Core::DispatchOutboxEventJob.perform_later(event.id) }

    assert_not_nil event.reload.published_at
  end
end
