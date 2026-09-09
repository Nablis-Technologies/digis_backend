# frozen_string_literal: true

# Registers ticketing handlers without replacing handlers owned by other
# domains. Messaging can replace the sender seam when its adapter is ready.
Rails.application.config.x.invitation_delivery_sender ||= ->(**_details) { nil }
Rails.application.config.x.consent_reminder_sender ||= ->(**_details) { nil }
Rails.application.config.x.credential_delivery_sender ||= ->(**_details) { nil }
Rails.application.config.x.credential_requirement_status_adapter ||= Ticketing::Credentials::NullRequirementStatusAdapter.new
Rails.application.config.x.outbox_handlers.register("ticketing.invitation.created", priority: 100) do |outbox_event|
  Ticketing::DeliverInvitationJob.perform_later(outbox_event.payload.fetch("invitation_id"))
end
Rails.application.config.x.outbox_handlers.register("ticketing.ticket_transfer.initiated", priority: 100) do |outbox_event|
  Ticketing::TicketTransferDeliveryJob.perform_later(outbox_event.payload.fetch("transfer_id"))
end

# Cancellation and decline are already persisted and audited by their domain
# commands. Acknowledge them explicitly until a downstream notification
# contract exists so terminal events do not retry forever.
%w[cancelled declined].each do |status|
  Rails.application.config.x.outbox_handlers.register("ticketing.ticket_transfer.#{status}", priority: 100) do |outbox_event|
    outbox_event
  end
end

Rails.application.config.x.outbox_handlers.register("ticketing.registration_consent.reminder_due", priority: 100) do |outbox_event|
  Rails.application.config.x.consent_reminder_sender.call(
    requirement_id: outbox_event.payload.fetch("requirement_id")
  )
end
Rails.application.config.x.outbox_handlers.register("ticketing.consent_credential_requirements_changed", priority: 100) do |outbox_event|
  Rails.application.config.x.credential_requirement_status_adapter.call(
    event_id: outbox_event.id,
    idempotency_key: outbox_event.idempotency_key,
    registration_id: outbox_event.payload.fetch("registration_id"),
    status: outbox_event.payload.fetch("status"),
    affected_coordinates: outbox_event.payload.fetch("affected_coordinates")
  )
end
Rails.application.config.x.outbox_handlers.register("ticketing.attendee_export.requested", priority: 100) do |outbox_event|
  Ticketing::GenerateAttendeeExportJob.perform_later(outbox_event.payload.fetch("attendee_export_id"))
end
Rails.application.config.x.outbox_handlers.register("ticketing.attendee_export.purge_requested", priority: 100) do |outbox_event|
  Ticketing::PurgeAttendeeExportJob.perform_later(outbox_event.payload.fetch("attendee_export_id"))
end
Rails.application.config.x.outbox_handlers.register("ticketing.registration.issuance_ready", priority: 100) do |outbox_event|
  result = Ticketing::OutboxHandlers::RegistrationIssuanceReady.call(event: outbox_event)
  raise result.error if result.failure?
  result
end

Rails.application.config.x.outbox_handlers.register("orders.payment.fulfilled", priority: 100) do |outbox_event|
  result = Ticketing::OutboxHandlers::OrderFulfilled.call(event: outbox_event)
  raise result.error if result.failure?
  result
end

Rails.application.config.x.outbox_handlers.register("ticketing.package_issued", priority: 100) do |outbox_event|
  result = Ticketing::OutboxHandlers::PackageIssued.call(event: outbox_event)
  raise result.error if result.failure?
  result
end

Rails.application.config.x.outbox_handlers.register("ticketing.credential_generation_replaced", priority: 100) do |outbox_event|
  result = Ticketing::OutboxHandlers::CredentialGenerationReplaced.call(event: outbox_event)
  raise result.error if result.failure?
  streaming = Streaming::OutboxHandlers::RevokeTicketSessions.call(event: outbox_event)
  raise streaming.error if streaming.failure?

  result
end

# Terminal refund events own the credential-side transition; failed date
# refunds restore eligibility through a new generation rather than reviving a
# historical QR/PNR generation.
%w[orders.refund.succeeded orders.refund.failed].each do |event_type|
  Rails.application.config.x.outbox_handlers.register(event_type, priority: 100) do |outbox_event|
    refund = Orders::Refund.includes(refund_items: [ :ticket, :event_date ]).find(
      outbox_event.payload.fetch("refund_id")
    )
    refund_item = refund.refund_items.one? ? refund.refund_items.first : nil
    result = if event_type == "orders.refund.succeeded" && refund_item&.event_date_id
      Ticketing::ApplyDateRefund.call(refund:)
    elsif event_type == "orders.refund.succeeded" && refund_item&.ticket_id
      Ticketing::CancelPaidPackage.call(ticket: refund_item.ticket, refund:)
    elsif event_type == "orders.refund.failed" && refund_item&.event_date_id
      Ticketing::RestoreFailedDateRefund.call(refund:)
    else
      Core::BaseService::Result.success(refund)
    end
    raise result.error if result.failure?
    result
  end
end
