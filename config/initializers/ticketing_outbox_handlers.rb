# frozen_string_literal: true

# Registers ticketing handlers without replacing handlers owned by other
# domains. Messaging can replace the sender seam when its adapter is ready.
Rails.application.config.x.invitation_delivery_sender ||= ->(**_details) { nil }
Rails.application.config.x.outbox_handlers["ticketing.invitation.created"] = lambda do |outbox_event|
  Ticketing::DeliverInvitationJob.perform_later(outbox_event.payload.fetch("invitation_id"))
end
