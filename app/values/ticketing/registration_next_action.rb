# frozen_string_literal: true

module Ticketing
  # The truthful handoff after submission. Confirmation and allocation remain
  # deliberately deferred until their owning workflow is available.
  RegistrationNextAction = Data.define(:registration, :type) do
    def self.for(registration, free: false)
      new(registration:, type: registration.next_action_snapshot.presence || type_for(registration.status, free:))
    end

    def self.type_for(status, free:)
      if status == "pending_approval"
        "awaiting_approval"
      elsif free
        "requires_confirmation"
      else
        "requires_order"
      end
    end
  end
end
