# frozen_string_literal: true

module Events
  module Cancellation
    # Permanently voids one free ticket during event shutdown. Free tickets
    # have no accepted payment and therefore never create a refund obligation;
    # credential and attendee-index tombstones still make the revocation
    # visible to online and offline admission paths.
    class RevokeFreeTicket < Core::BaseService
      def initialize(ticket:)
        @ticket = ticket
      end

      def call
        outcome = nil
        Ticketing::Ticket.transaction do
          ticket = Ticketing::Ticket.includes(:event, :revocation).lock.find(@ticket.id)
          if ticket.status == "void"
            outcome = success(ticket)
            next
          end
          unless Ticketing::Ticket::FREE_ACQUISITION_TYPES.include?(ticket.current_acquisition_type)
            outcome = failure(cancellation_error(:cancellation_failed))
            next
          end

          generation = ticket.credential_generations.includes(:credentials).lock.find_by(status: "active")
          if generation
            revocation = Ticketing::Revocations::PublishGeneration.call(
              ticket:,
              through_version: generation.version,
              reason: "event_cancelled_free_ticket"
            )
            raise revocation.error if revocation.failure?
            generation.credentials.each do |credential|
              projection = Ticketing::AttendeeIndex::Upsert.call(
                credential:, loaded_credential: credential, removed: true
              )
              raise projection.error if projection.failure?
            end
            Ticketing::Revocation.lock.find_by!(ticket_id: ticket.id).update!(
              is_dead: true,
              is_suspended: false
            )
          end
          ticket.update!(status: "void")
          outcome = success(ticket)
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(cancellation_error(:cancellation_failed, :not_found))
      rescue ActiveRecord::RecordInvalid => error
        failure(cancellation_error(:cancellation_failed, errors: error.record.errors.to_hash))
      rescue Core::Error => error
        failure(error)
      end

      private

      def cancellation_error(key, status = :unprocessable_entity, errors: nil)
        Core::BusinessError.new(
          I18n.t("events.cancellation.errors.#{key}"), code: key, status:, errors:
        )
      end
    end
  end
end
