# frozen_string_literal: true

# Registers ticketing handlers without replacing handlers owned by other
# domains. Messaging can replace the sender seam when its adapter is ready.
Rails.application.config.x.invitation_delivery_sender ||= ->(**_details) { nil }
Rails.application.config.x.consent_reminder_sender ||= ->(**_details) { nil }
Rails.application.config.x.registration_notification_sender ||= ->(**_details) { nil }
Rails.application.config.x.credential_requirement_status_adapter ||= Ticketing::Credentials::NullRequirementStatusAdapter.new
Rails.application.config.x.outbox_handlers["ticketing.invitation.created"] = lambda do |outbox_event|
  Ticketing::DeliverInvitationJob.perform_later(outbox_event.payload.fetch("invitation_id"))
end
Rails.application.config.x.outbox_handlers["ticketing.registration_consent.reminder_due"] = lambda do |outbox_event|
  Rails.application.config.x.consent_reminder_sender.call(
    requirement_id: outbox_event.payload.fetch("requirement_id")
  )
end
Rails.application.config.x.outbox_handlers["ticketing.consent_credential_requirements_changed"] = lambda do |outbox_event|
  Rails.application.config.x.credential_requirement_status_adapter.call(
    event_id: outbox_event.id,
    idempotency_key: outbox_event.idempotency_key,
    registration_id: outbox_event.payload.fetch("registration_id"),
    status: outbox_event.payload.fetch("status"),
    affected_coordinates: outbox_event.payload.fetch("affected_coordinates")
  )
end
# Registration notifications carry only a registration ID and event type; the
# injected sender decides whether SMS/email delivery is available.
%w[
  ticketing.registration.waitlist_offer_created
  ticketing.registration.issuance_ready
  ticketing.registration.rejected
].each do |event_type|
  Rails.application.config.x.outbox_handlers[event_type] = lambda do |outbox_event|
    Ticketing::RegistrationNotificationJob.perform_later(
      outbox_event.payload.fetch("registration_id"),
      outbox_event.event_type
    )
  end
end
