# frozen_string_literal: true

require "test_helper"

class OutboxHandlerRegistryTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "runs handlers in priority then registration order" do
    registry = Core::Outbox::HandlerRegistry.new
    calls = []
    registry.register("event", priority: 200) { calls << :later }
    registry.register("event", priority: 100) { calls << :first }
    registry.register("event", priority: 200) { calls << :second }

    registry.fetch("event").call(Object.new)

    assert_equal [ :first, :later, :second ], calls
  end

  test "bracket assignment and lookup preserve the single-handler contract" do
    registry = Core::Outbox::HandlerRegistry.new
    handler = ->(_event) { :handled }
    registry["event"] = handler

    assert registry.key?("event")
    assert_respond_to registry["event"], :call
    assert_equal :handled, registry.fetch("event").call(Object.new)
  end

  test "namespace handlers are independent from exact handlers" do
    registry = Core::Outbox::HandlerRegistry.new
    registry.register_namespace("orders") { :namespace }
    registry.register("orders.completed") { :exact }

    assert_equal :exact, registry.fetch("orders.completed").call(Object.new)
    assert_equal :namespace, registry.fetch_namespace("orders").call(Object.new)
  end

  test "keeps exact and namespace keys isolated in one registry" do
    registry = Core::Outbox::HandlerRegistry.new
    registry.register("orders") { :exact }
    registry.register_namespace("orders") { :namespace }

    assert_equal :exact, registry.fetch("orders").call(Object.new)
    assert_equal :namespace, registry.fetch_namespace("orders").call(Object.new)
    assert registry.key?("orders")
  end

  test "raises a returned failure result before invoking later handlers" do
    registry = Core::Outbox::HandlerRegistry.new
    failure = Core::Error.new("handler failed")
    calls = []
    registry.register("event") { Core::BaseService::Result.failure(failure) }
    registry.register("event") { calls << :later }

    raised = assert_raises(Core::Error) { registry.fetch("event").call(Object.new) }

    assert_same failure, raised
    assert_empty calls
  end

  test "empty keys return nil" do
    registry = Core::Outbox::HandlerRegistry.new

    assert_nil registry.fetch("missing")
    assert_nil registry.fetch_namespace("missing")
  end
end
