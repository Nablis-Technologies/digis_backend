# frozen_string_literal: true

require "test_helper"

class Core::DispatchOutboxEventJobTest < ActiveJob::TestCase
  include Ticketing::PackageWorkflowTestHelpers
  include MessagingTestHelpers

  setup do
    # Preserve the real registry registered by initializers; these tests mutate
    # the global handler configuration and must restore it between examples.
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
    registry = Core::Outbox::HandlerRegistry.new
    registry.register(event.event_type, &handler)

    Rails.application.config.x.outbox_handlers = registry
    perform_enqueued_jobs { Core::DispatchOutboxEventJob.perform_later(event.id) }

    assert_not_nil event.reload.published_at
  end

  test "retries a messaging billing handler when it returns a failure result" do
    event = core_outbox_events(:pending)
    event.update!(
      topic: "orders", event_type: "orders.billing_payment.accepted",
      payload: { "source_type" => "Messaging::CreditTopUp" }
    )
    failure = Core::BaseService::Result.failure(Core::Error.new("grant failed"))
    Messaging::OutboxHandlers::GrantTopUpCredits.expects(:call).returns(failure)

    assert_raises(Core::Error) { Core::Outbox::Dispatch.call(event_id: event.id) }

    assert_nil event.reload.published_at
    assert_equal "Core::Error", event.last_error_code
  end

  test "prefers an exact handler over a namespace handler" do
    event = core_outbox_events(:pending)
    event.update!(topic: "commercial", event_type: "commercial.example")
    calls = []
    registry = Core::Outbox::HandlerRegistry.new
    registry.register(event.event_type) { calls << :exact }
    registry.register_namespace("commercial") { calls << :namespace }
    Rails.application.config.x.outbox_handlers = registry
    Rails.application.config.x.outbox_namespace_handlers = registry

    Core::Outbox::Dispatch.call(event_id: event.id)

    assert_equal [ :exact ], calls
    assert event.reload.published_at?
  end

  test "uses a namespace handler for non-security events" do
    event = core_outbox_events(:pending)
    event.update!(topic: "commercial", event_type: "commercial.example")
    calls = []
    registry = Core::Outbox::HandlerRegistry.new
    registry.register_namespace("commercial") { calls << :namespace }
    Rails.application.config.x.outbox_handlers = registry
    Rails.application.config.x.outbox_namespace_handlers = registry

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

  test "registers evidence handlers for checkout lifecycle events" do
    assert Rails.application.config.x.outbox_handlers.key?("orders.checkout.created")
    assert Rails.application.config.x.outbox_handlers.key?("orders.checkout.expired")
  end

  test "enqueues transfer delivery for an initiated ticket transfer" do
    setup_package_workflow(admissions_per_unit: 1)
    create_messaging_policy
    initiated = Ticketing::Transfers::Initiate.call(
      ticket: @ticket,
      actor: @owner,
      phone: @recipient.phone,
      idempotency_key: "outbox-transfer-delivery"
    )
    assert_predicate initiated, :success?, initiated.error&.message

    transfer_id = initiated.value.transfer.id
    event = Core::OutboxEvent.find_by!(
      aggregate_id: transfer_id,
      event_type: "ticketing.ticket_transfer.initiated"
    )

    assert_enqueued_with(job: Ticketing::TicketTransferDeliveryJob, args: [ transfer_id ]) do
      Core::Outbox::Dispatch.call(event_id: event.id)
    end
    assert event.reload.published_at?
    assert Messaging::Notification.exists?(source_id: transfer_id, notification_type: "transfer_incoming")
  end

  test "acknowledges cancelled ticket transfer events without downstream jobs" do
    assert_terminal_ticket_transfer_acknowledged("cancelled")
  end

  test "acknowledges declined ticket transfer events without downstream jobs" do
    assert_terminal_ticket_transfer_acknowledged("declined")
  end

  test "acknowledges event completion evidence without enqueueing maturity" do
    event = core_outbox_events(:pending)
    event.update!(
      topic: "events",
      event_type: "event.completed",
      payload: { event_id: SecureRandom.uuid, completed_at: Time.current.iso8601 }
    )

    assert_no_enqueued_jobs do
      Core::Outbox::Dispatch.call(event_id: event.id)
    end

    assert event.reload.published_at?
  end

  test "publishes checkout lifecycle evidence without a downstream consumer" do
    event = core_outbox_events(:pending)
    event.update!(topic: "orders", event_type: "orders.checkout.created")

    Core::Outbox::Dispatch.call(event_id: event.id)

    assert event.reload.published_at?
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
    registry = Core::Outbox::HandlerRegistry.new
    registry.register_namespace("commercial") { calls << :namespace }
    Rails.application.config.x.outbox_handlers = registry
    Rails.application.config.x.outbox_namespace_handlers = registry

    assert_raises(Core::Outbox::Dispatch::MissingHandler) do
      Core::Outbox::Dispatch.call(event_id: event.id)
    end

    assert_empty calls
    assert_nil event.reload.published_at
  end

  private

  def assert_terminal_ticket_transfer_acknowledged(status)
    event = core_outbox_events(:pending)
    event.update!(
      topic: "ticketing",
      event_type: "ticketing.ticket_transfer.#{status}",
      payload: { "transfer_id" => SecureRandom.uuid, "ticket_id" => SecureRandom.uuid }
    )

    assert_no_enqueued_jobs do
      Core::Outbox::Dispatch.call(event_id: event.id)
    end

    assert event.reload.published_at?
  end
end
