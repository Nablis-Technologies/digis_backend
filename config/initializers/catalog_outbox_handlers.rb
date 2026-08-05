# frozen_string_literal: true

# Catalog lifecycle handlers delegate notifications without replacing handlers
# registered by Core, Events, or other domains.
Rails.application.config.x.catalog_notification_sender ||= ->(**_details) { nil }

%w[catalog.product.activated catalog.product.retired].each do |event_type|
  Rails.application.config.x.outbox_handlers[event_type] = lambda do |outbox_event|
    Catalog::NotifyProductStatusChangedJob.perform_later(
      outbox_event.payload.fetch("product_id"),
      outbox_event.event_type
    )
  end
end
