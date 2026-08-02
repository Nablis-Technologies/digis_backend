# frozen_string_literal: true

module Ticketing
  # Delivers an invitation through the provider registered by Messaging. The
  # token is decrypted only at this boundary and is never placed in a job
  # argument or outbox payload.
  class DeliverInvitationJob < ApplicationJob
    queue_as :default

    def perform(invitation_id)
      invitation = Ticketing::Invitation.find_by(id: invitation_id)
      return unless invitation&.status == "pending"

      sender = Rails.application.config.x.invitation_delivery_sender
      return unless sender.respond_to?(:call)

      sender.call(invitation:, token: invitation.token)
    end
  end
end
