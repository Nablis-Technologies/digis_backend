# frozen_string_literal: true

require "set"

module Ticketing
  module OutboxHandlers
    # Completes free, complimentary, and walk-up registration fulfillment
    # through the same package command used by paid orders. Package issuance
    # publishes its own durable event for downstream notification projection.
    class RegistrationIssuanceReady < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        outcome = nil
        ActiveRecord::Base.transaction do
          registration = load_registration
          event_id = registration.event_id
          event = Events::Event.lock.find(event_id)
          return success(registration) if event.status == "cancelled"
          Core::Database::AdvisoryLock.acquire!("ticketing-package-issuance", event_id)
          Core::Database::AdvisoryLock.acquire!("ticketing-attendee-index", event_id)
          context = issuance_context(event_id)
          existing_tickets = Ticketing::Ticket.where(registration_id: registration.id).to_a.index_by(&:unit_number)
          1.upto(registration.package_quantity) do |unit_number|
            issuance = Ticketing::Packages::Issue.call(
              registration:,
              unit_number:,
              source: registration,
              existing_ticket: existing_tickets[unit_number],
              reload_ticket: false,
              issuance_context: context,
              event:, index_lock_held: true
            )
            next if issuance.success?

            outcome = failure(issuance.error)
            raise ActiveRecord::Rollback
          end
          outcome = success(registration)
        end
        outcome
      rescue ActiveRecord::RecordNotFound, KeyError
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_issuance.errors.invalid_registration_event"),
            code: "invalid_registration_event",
            status: :unprocessable_entity
          )
        )
      end

      private

      def load_registration
        Ticketing::Registration.includes(
          :user,
          :event,
          :consent_requirements,
          ticket_type: { event_product: [ :ticket_type, { product_accesses: :event_date } ] }
        ).find(@event.payload.fetch("registration_id"))
      end

      def issuance_context(event_id)
        {
          reserved_lookup_codes: Ticketing::Credential.where(event_id:).where.not(lookup_code: nil).pluck(:lookup_code).to_set
        }
      end
    end
  end
end
