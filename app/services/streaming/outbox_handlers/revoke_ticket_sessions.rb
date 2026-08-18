# frozen_string_literal: true

module Streaming
  module OutboxHandlers
    # Converts lifecycle outbox rows into a bounded revocation job. Only
    # durable ticket/event IDs cross the outbox boundary; sessions are queried
    # under lock by the job after the source transaction has committed.
    class RevokeTicketSessions < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        return failure(invalid_event) unless @event.payload.is_a?(Hash)

        payload = @event.payload.deep_stringify_keys
        ticket_id = payload["ticket_id"]
        event_id = payload["event_id"]
        return failure(invalid_event) if ticket_id.blank? && event_id.blank?

        Streaming::RevokeTicketSessionsJob.perform_later(
          ticket_id:,
          event_id:,
          idempotency_key: @event.idempotency_key
        )
        success(@event)
      rescue KeyError
        failure(invalid_event)
      end

      private

      def invalid_event
        Core::BusinessError.new(
          I18n.t("streaming.errors.invalid_lifecycle_event"),
          code: "invalid_lifecycle_event",
          status: :unprocessable_entity
        )
      end
    end
  end
end
