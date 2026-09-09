# frozen_string_literal: true

module Ticketing
  module OutboxHandlers
    # Delegates free, complimentary, and walk-up registration fulfillment to the
    # shared registration package command used by synchronous and outbox paths.
    class RegistrationIssuanceReady < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        Ticketing::Registrations::IssuePackages.call(
          registration_id: @event.payload.fetch("registration_id")
        )
      rescue ActiveRecord::RecordNotFound, KeyError
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_issuance.errors.invalid_registration_event"),
            code: "invalid_registration_event",
            status: :unprocessable_entity
          )
        )
      end
    end
  end
end
