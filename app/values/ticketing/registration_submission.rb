# frozen_string_literal: true

module Ticketing
  # Immutable client input for one registration attempt. The command enriches
  # it with server-owned identity, ticket, form-schema, and exact consent evidence.
  RegistrationSubmission = Data.define(
    :package_quantity, :selected_event_date_id, :answers, :consents
  ) do
    alias_method :initialize_members, :initialize

    def initialize(package_quantity:, selected_event_date_id:, answers:, consents: [])
      initialize_members(
        package_quantity:,
        selected_event_date_id:,
        answers:,
        consents:
      )
    end
  end
end
