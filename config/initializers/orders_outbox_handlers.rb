# frozen_string_literal: true

# Orders handlers enqueue only durable IDs. The inbox/refund rows retain the
# provider evidence, while Solid Queue retries the command that owns the lock
# and idempotency rules.
Rails.application.config.x.outbox_handlers["orders.payment_event.received"] = lambda do |outbox_event|
  Orders::ProcessPaymentEventJob.perform_later(outbox_event.payload.fetch("payment_event_id"))
end

Rails.application.config.x.outbox_handlers["orders.payment_reversal.created"] = lambda do |outbox_event|
  Orders::SubmitRefundJob.perform_later(outbox_event.payload.fetch("refund_id"))
end

Rails.application.config.x.outbox_handlers["orders.refund.created"] = lambda do |outbox_event|
  # Date refunds version credentials before the provider job is enqueued, so
  # an online or offline admission cannot race a newly-created refund.
  refund = Orders::Refund.includes(refund_items: [ :ticket, :event_date ]).find(
    outbox_event.payload.fetch("refund_id")
  )
  refund_item = refund.refund_items.one? ? refund.refund_items.first : nil
  if refund_item&.event_date_id
    result = Ticketing::ApplyDateRefund.call(refund:)
    raise result.error if result.failure?
  end
  Orders::SubmitRefundJob.perform_later(outbox_event.payload.fetch("refund_id"))
end
