# frozen_string_literal: true

# Commercial transitions currently use outbox rows as durable evidence without
# requiring a downstream job. Exact event handlers can replace this fallback
# later; security-topic events are excluded by Core::Outbox::Dispatch.
Rails.application.config.x.outbox_namespace_handlers.register_namespace("commercial", priority: 100) do |outbox_event|
  Rails.logger.warn(
    "Commercial outbox evidence acknowledged without downstream consumer: " \
    "event_id=#{outbox_event.id} event_type=#{outbox_event.event_type}"
  )
end

Rails.application.config.x.outbox_handlers.register("commercial.security.break_glass", priority: 100) do |outbox_event|
  result = Commercial::OutboxHandlers::BreakGlass.call(event: outbox_event)
  raise result.error if result.failure?

  result
end
