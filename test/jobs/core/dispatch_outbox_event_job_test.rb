# frozen_string_literal: true

require "test_helper"

class Core::DispatchOutboxEventJobTest < ActiveJob::TestCase
  setup do
    # Preserve the real handlers registered by initializers; this test mutates
    # the global outbox_handlers hash and must restore it so later tests in
    # the same worker are not polluted.
    @original_outbox_handlers = Rails.application.config.x.outbox_handlers
    @original_outbox_namespace_handlers = Rails.application.config.x.outbox_namespace_handlers
  end

  teardown do
    Rails.application.config.x.outbox_handlers = @original_outbox_handlers
    Rails.application.config.x.outbox_namespace_handlers = @original_outbox_namespace_handlers
  end

  test "marks the event published only after the handler succeeds" do
    event = core_outbox_events(:pending)
    handler = ->(outbox_event) { assert_equal event.id, outbox_event.id }

    Rails.application.config.x.outbox_handlers = { event.event_type => handler }
    perform_enqueued_jobs { Core::DispatchOutboxEventJob.perform_later(event.id) }

    assert_not_nil event.reload.published_at
  end

  test "prefers an exact handler over a namespace handler" do
    event = core_outbox_events(:pending)
    event.update!(topic: "commercial", event_type: "commercial.example")
    calls = []
    Rails.application.config.x.outbox_handlers = {
      event.event_type => ->(_outbox_event) { calls << :exact }
    }
    Rails.application.config.x.outbox_namespace_handlers = {
      "commercial" => ->(_outbox_event) { calls << :namespace }
    }

    Core::Outbox::Dispatch.call(event_id: event.id)

    assert_equal [ :exact ], calls
    assert event.reload.published_at?
  end

  test "uses a namespace handler for non-security events" do
    event = core_outbox_events(:pending)
    event.update!(topic: "commercial", event_type: "commercial.example")
    calls = []
    Rails.application.config.x.outbox_handlers = {}
    Rails.application.config.x.outbox_namespace_handlers = {
      "commercial" => ->(_outbox_event) { calls << :namespace }
    }

    Core::Outbox::Dispatch.call(event_id: event.id)

    assert_equal [ :namespace ], calls
    assert event.reload.published_at?
  end

  test "registers the commercial namespace evidence handler" do
    assert Rails.application.config.x.outbox_namespace_handlers.key?("commercial")
  end

  test "registers an explicit break-glass handler" do
    assert Rails.application.config.x.outbox_handlers.key?("commercial.security.break_glass")
  end

  test "dispatches break-glass events through the explicit handler" do
    event = core_outbox_events(:pending)
    event.update!(
      topic: "security",
      event_type: "commercial.security.break_glass",
      aggregate_type: "Commercial::Assignment",
      aggregate_id: SecureRandom.uuid,
      payload: { assignment_id: SecureRandom.uuid, operation: "assignment_approve" }
    )

    Core::Outbox::Dispatch.call(event_id: event.id)

    assert event.reload.published_at?
  end

  test "does not use a namespace handler for security events" do
    event = core_outbox_events(:pending)
    event.update!(topic: "security", event_type: "commercial.security.break_glass")
    calls = []
    Rails.application.config.x.outbox_handlers = {}
    Rails.application.config.x.outbox_namespace_handlers = {
      "commercial" => ->(_outbox_event) { calls << :namespace }
    }

    assert_raises(Core::Outbox::Dispatch::MissingHandler) do
      Core::Outbox::Dispatch.call(event_id: event.id)
    end

    assert_empty calls
    assert_nil event.reload.published_at
  end
end
