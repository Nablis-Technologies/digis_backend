# frozen_string_literal: true

# Orders handlers enqueue only durable IDs. The inbox/refund rows retain the
# provider evidence, while Solid Queue retries the command that owns the lock
# and idempotency rules.
Rails.application.config.x.outbox_handlers["orders.payment_event.received"] = lambda do |outbox_event|
  Orders::ProcessPaymentEventJob.perform_later(outbox_event.payload.fetch("payment_event_id"))
end

Rails.application.config.x.outbox_handlers["orders.payment_reversal.created"] = lambda do |outbox_event|
  Orders::ReconcilePaymentJob.perform_later(outbox_event.payload.fetch("refund_id"))
end
