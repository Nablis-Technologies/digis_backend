# frozen_string_literal: true

# Streaming owns only the lifecycle event types it introduces or consumes.
# Event cancellation is composed in the existing Events initializer because
# that event already has an authoritative domain handler.
%w[
  ticketing.ticket_suspension.changed
  ticketing.package_refunded
  marketplace.resale_listing.reserved
].each do |event_type|
  Rails.application.config.x.outbox_handlers[event_type] = lambda do |outbox_event|
    result = Streaming::OutboxHandlers::RevokeTicketSessions.call(event: outbox_event)
    raise result.error if result.failure?

    result
  end
end
