# frozen_string_literal: true

# Registers event-domain outbox handlers. Each handler receives the
# Core::OutboxEvent and is responsible for its own idempotency. The registered
# handler is invoked by Core::Outbox::Dispatch (via Core::ProcessOutboxJob) once
# an "event.published" outbox row is claimed for delivery.
Rails.application.config.x.outbox_handlers["event.published"] = lambda do |outbox_event|
  event_id = outbox_event.payload["event_id"]
  Events::RefreshDiscoveryJob.perform_later(event_id)
end
