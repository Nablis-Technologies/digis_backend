# frozen_string_literal: true

# Registers event-domain outbox handlers. Each handler receives the
# Core::OutboxEvent and is responsible for its own idempotency. The registered
# handler is invoked by Core::Outbox::Dispatch (via Core::ProcessOutboxJob) once
# an "event.published" outbox row is claimed for delivery.
Rails.application.config.x.outbox_handlers.register("event.published", priority: 100) do |outbox_event|
  event_id = outbox_event.payload.fetch("event_id")
  Events::RefreshDiscoveryJob.perform_later(event_id)
  Commercial::HandleEventPublishedJob.perform_later(event_id)
end

# Completion already enqueues maturity inside Finance::CompleteEvent after its
# transaction commits. This handler acknowledges the durable completion signal
# without scheduling a second maturity job.
Rails.application.config.x.outbox_handlers.register("event.completed", priority: 100) do |outbox_event|
  outbox_event.payload.fetch("event_id")
  Rails.logger.info(
    "Event completion evidence acknowledged without a downstream consumer: " \
    "event_id=#{outbox_event.id} event_type=#{outbox_event.event_type}"
  )
end

Rails.application.config.x.outbox_handlers.register("events.cancellation_initiated", priority: 100) do |outbox_event|
  result = Events::Cancellation::OutboxHandlers::CancellationInitiated.call(event: outbox_event)
  raise result.error if result.failure?
  streaming = Streaming::OutboxHandlers::RevokeTicketSessions.call(event: outbox_event)
  raise streaming.error if streaming.failure?

  result
end

Rails.application.config.x.outbox_handlers.register("events.staff_invitation.delivery_requested", priority: 100) do |outbox_event|
  Events::DeliverStaffInvitationJob.perform_later(
    outbox_event.payload.fetch("invitation_id"),
    outbox_event.payload.fetch("delivery_revision")
  )
end
