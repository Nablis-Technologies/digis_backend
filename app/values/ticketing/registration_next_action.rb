# frozen_string_literal: true

module Ticketing
  # The truthful handoff after submission. Confirmation and allocation remain
  # deliberately deferred until their owning workflow is available.
  RegistrationNextAction = Data.define(:registration, :type) do
    TYPES_BY_STATUS = {
      "pending_approval" => "awaiting_approval",
      "pending_payment" => "requires_order",
      "gift_pending_claim" => "gift_claim_pending",
      "offered" => "requires_order",
      "waitlisted" => "waitlisted",
      "confirmed" => "confirmed",
      "rejected" => "rejected",
      "cancelled" => "cancelled",
      "expired" => "expired"
    }.freeze

    def self.for(registration)
      new(registration:, type: registration.next_action_snapshot.presence || type_for(registration.status))
    end

    def self.type_for(status)
      TYPES_BY_STATUS.fetch(status.to_s, status.to_s)
    end
  end
end
