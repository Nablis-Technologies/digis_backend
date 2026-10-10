# frozen_string_literal: true

Rails.application.config.x.outbox_handlers.register(
  "organizations.membership_invitation.delivery_requested",
  priority: 100
) do |outbox_event|
  Organizations::DeliverMembershipInvitationJob.perform_later(
    outbox_event.payload.fetch("invitation_id"),
    outbox_event.payload.fetch("delivery_revision")
  )
end
