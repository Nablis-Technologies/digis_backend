# frozen_string_literal: true

Rails.application.config.after_initialize do
  {
    "orders.billing_payment.accepted" => Finance::OutboxHandlers::PlatformBillingPaymentAccepted,
    "orders.refund.succeeded" => Finance::OutboxHandlers::PlatformBillingRefundSucceeded
  }.each do |event_type, handler_class|
    Rails.application.config.x.outbox_handlers.register(event_type, priority: 250) do |outbox_event|
      result = handler_class.call(event: outbox_event)
      raise result.error if result.failure?

      result
    end
  end
end
