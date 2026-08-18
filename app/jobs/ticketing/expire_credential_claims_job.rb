# frozen_string_literal: true

module Ticketing
  # Marks overdue pending claims terminal without touching accepted
  # credentials. A later invitation may create a new claim only after the
  # prior row is explicitly revoked or the credential is replaced.
  class ExpireCredentialClaimsJob < ApplicationJob
    queue_as :default

    def perform
      Ticketing::CredentialClaim
        .where(status: "pending")
        .where("expires_at IS NOT NULL AND expires_at <= ?", Time.current)
        .update_all(status: "expired", updated_at: Time.current)
    end
  end
end
