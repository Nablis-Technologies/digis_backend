# frozen_string_literal: true

# Marketplace transitions currently use outbox rows as durable evidence without
# requiring a downstream job. Exact event handlers can replace this fallback
# later; security-topic events are excluded by Core::Outbox::Dispatch.
Rails.application.config.x.outbox_namespace_handlers.register_namespace("marketplace", priority: 100) do |outbox_event|
  Rails.logger.info(
    "Marketplace outbox evidence acknowledged without downstream consumer: " \
    "event_id=#{outbox_event.id} event_type=#{outbox_event.event_type}"
  )
end
