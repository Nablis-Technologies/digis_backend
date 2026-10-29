# frozen_string_literal: true

require "test_helper"

class OutboxDispatchTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @original_handlers = Rails.application.config.x.outbox_handlers
    @original_namespace_handlers = Rails.application.config.x.outbox_namespace_handlers
  end

  teardown do
    Rails.application.config.x.outbox_handlers = @original_handlers
    Rails.application.config.x.outbox_namespace_handlers = @original_namespace_handlers
  end

  test "replays an earlier idempotent handler when a later handler fails" do
    event = create_outbox_event
    calls = []
    Rails.application.config.x.outbox_handlers = Core::Outbox::HandlerRegistry.new
    Rails.application.config.x.outbox_handlers.register(event.event_type, priority: 100) { calls << :domain }
    Rails.application.config.x.outbox_handlers.register(event.event_type, priority: 200) do
      calls << :messaging
      raise Core::Error, "delivery failed"
    end

    Prosopite.pause do
      2.times { assert_raises(Core::Error) { Core::Outbox::Dispatch.call(event_id: event.id) } }
    end

    assert_equal [ :domain, :messaging, :domain, :messaging ], calls
    assert_nil event.reload.published_at
  end

  test "prefers an exact handler over a namespace handler" do
    event = create_outbox_event
    event.update!(topic: "orders", event_type: "orders.example")
    calls = []
    exact = Core::Outbox::HandlerRegistry.new
    namespace = Core::Outbox::HandlerRegistry.new
    exact.register(event.event_type) { calls << :exact }
    namespace.register_namespace("orders") { calls << :namespace }
    Rails.application.config.x.outbox_handlers = exact
    Rails.application.config.x.outbox_namespace_handlers = namespace

    Core::Outbox::Dispatch.call(event_id: event.id)

    assert_equal [ :exact ], calls
    assert event.reload.published_at?
  end

  test "keeps security topics out of namespace fallback" do
    event = create_outbox_event
    event.update!(topic: "security", event_type: "security.example")
    Rails.application.config.x.outbox_handlers = Core::Outbox::HandlerRegistry.new
    namespace = Core::Outbox::HandlerRegistry.new
    namespace.register_namespace("security") { :namespace }
    Rails.application.config.x.outbox_namespace_handlers = namespace

    assert_raises(Core::Outbox::Dispatch::MissingHandler) do
      Core::Outbox::Dispatch.call(event_id: event.id)
    end

    assert_nil event.reload.published_at
  end

  private

  def create_outbox_event
    Core::OutboxEvent.create!(
      topic: "orders",
      event_type: "orders.example",
      aggregate_type: "Core::OutboxEvent",
      aggregate_id: SecureRandom.uuid,
      payload: {},
      idempotency_key: "dispatch-test-#{SecureRandom.uuid}",
      occurred_at: Time.current,
      available_at: Time.current
    )
  end
end
