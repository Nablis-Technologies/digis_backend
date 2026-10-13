# frozen_string_literal: true

Rails.application.config.after_initialize do
  Rails.application.config.x.outbox_handlers.register("events.cancellation_initiated", priority: 150) do |outbox_event|
    result = Marketing::OutboxHandlers::EventCancelled.call(event: outbox_event)
    raise result.error if result.failure?

    result
  end

  {
    "orders.billing_payment.accepted" => Marketing::OutboxHandlers::BillingPaymentAccepted,
    "orders.billing_payment.failed" => Marketing::OutboxHandlers::BillingPaymentLifecycle,
    "orders.billing_payment.reversed" => Marketing::OutboxHandlers::BillingPaymentLifecycle
  }.each do |event_type, handler_class|
    Rails.application.config.x.outbox_handlers.register(event_type, priority: 150) do |outbox_event|
      result = handler_class.call(event: outbox_event)
      raise result.error if result.failure?

      result
    end
  end
end
