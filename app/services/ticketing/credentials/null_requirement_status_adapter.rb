# frozen_string_literal: true

module Ticketing
  module Credentials
    # Explicit no-op boundary until Ticketing owns credential issuance and revocation.
    class NullRequirementStatusAdapter
      def call(event_id:, idempotency_key:, registration_id:, status:, affected_coordinates:)
        nil
      end
    end
  end
end
