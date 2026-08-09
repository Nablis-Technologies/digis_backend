# frozen_string_literal: true

module Ticketing
  # Immutable client input for one registration attempt. The command enriches
  # it with server-owned identity, ticket, and form-schema evidence.
  RegistrationSubmission = Data.define(:package_quantity, :selected_event_date_id, :answers)
end
