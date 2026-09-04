# frozen_string_literal: true

# Messaging composes after domain handlers. Domain handlers remain responsible
# for their own idempotency because a later notification failure replays them.
Rails.application.config.after_initialize do
  {
    "orders.billing_payment.accepted" => Messaging::OutboxHandlers::GrantTopUpCredits,
    "orders.billing_payment.failed" => Messaging::OutboxHandlers::ResolveTopUpPayment,
    "orders.billing_payment.reversed" => Messaging::OutboxHandlers::ResolveTopUpPayment
  }.each do |event_type, handler_class|
    Rails.application.config.x.outbox_handlers.register(event_type, priority: 200) do |outbox_event|
      result = handler_class.call(event: outbox_event)
      raise result.error if result.respond_to?(:failure?) && result.failure?

      result
    end
  end

  messaging_event_types = Messaging::OutboxHandlers::PublishTransactionalNotification::EVENT_TYPES.keys
  messaging_event_types.each do |event_type|
    Rails.application.config.x.outbox_handlers.register(event_type, priority: 200) do |outbox_event|
      result = Messaging::OutboxHandlers::PublishTransactionalNotification.call(event: outbox_event)
      raise result.error if result.failure?

      result
    end
  end
end
