# frozen_string_literal: true

require "set"

module Ticketing
  module Registrations
    # Issues every missing package unit for a confirmed registration under one
    # event/attendee lock set. Both synchronous RSVP issuance and the durable
    # issuance outbox use this command so retries share identical semantics.
    class IssuePackages < Core::BaseService
      Result = Data.define(:registration, :tickets, :complete)

      def initialize(registration_id:)
        @registration_id = registration_id
      end

      def call
        outcome = nil
        Ticketing::Registration.transaction do
          registration = load_registration
          event = Events::Event.lock.find(registration.event_id)
          existing = existing_tickets(registration)

          if event.status == "cancelled"
            outcome = success(result_for(registration, existing.values, complete: false))
            next
          end

          Core::Database::AdvisoryLock.acquire_all!(
            [ "ticketing-package-issuance", event.id ],
            [ "ticketing-attendee-index", event.id ]
          )
          outcome = issue_units(registration, event, existing)
        end
        outcome
      rescue Ticketing::Registrations::Support::Halt => error
        error.result
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
        ).find(@registration_id)
      end

      def existing_tickets(registration)
        Ticketing::Ticket.where(registration_id: registration.id).to_a.index_by(&:unit_number)
      end

      def issue_units(registration, event, existing)
        context = issuance_context(event.id)
        tickets = existing.values

        1.upto(registration.package_quantity) do |unit_number|
          next if existing.key?(unit_number)

          issuance = Ticketing::Packages::Issue.call(
            registration:,
            unit_number:,
            source: registration,
            existing_ticket: existing[unit_number],
            reload_ticket: false,
            issuance_context: context,
            event:,
            index_lock_held: true
          )
          if issuance.failure?
            raise Ticketing::Registrations::Support::Halt, issuance
          end

          tickets << issuance.value
        end

        success(result_for(registration, tickets, complete: tickets.length == registration.package_quantity))
      end

      def issuance_context(event_id)
        {
          reserved_lookup_codes: Ticketing::Credential.where(event_id:).where.not(lookup_code: nil).pluck(:lookup_code).to_set
        }
      end

      def result_for(registration, tickets, complete:)
        Result.new(registration:, tickets: tickets.sort_by(&:unit_number), complete:)
      end
    end
  end
end
