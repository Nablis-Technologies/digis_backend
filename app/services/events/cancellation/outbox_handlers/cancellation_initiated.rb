# frozen_string_literal: true

module Events
  module Cancellation
    module OutboxHandlers
      # Converts one committed cancellation outbox event into the resumable
      # coordinator. The handler passes only the durable event id and never
      # scans payments or performs provider work inside outbox delivery.
      class CancellationInitiated < Core::BaseService
        def initialize(event:)
          @event = event
        end

        def call
          cancellation = Events::EventCancellation.find_by!(event_id: @event.payload.fetch("event_id"))
          Events::Cancellation::PrepareBatch.call(cancellation:)
        rescue ActiveRecord::RecordNotFound, KeyError
          failure(
            Core::BusinessError.new(
              I18n.t("events.cancellation.errors.cancellation_failed"),
              code: "cancellation_failed",
              status: :not_found
            )
          )
        end
      end
    end
  end
end
