# frozen_string_literal: true

module Commercial
  # Consumes an event.published outbox delivery and reconciles first-event
  # entitlements by event id. Failed command results are raised so the job's
  # retry policy can handle transient failures instead of silently dropping the
  # reconciliation; deterministic business failures remain visible to the job
  # backend for operator review.
  class HandleEventPublishedJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(event_id)
      event = Events::Event.find_by(id: event_id)
      return unless event

      result = Commercial::Entitlements::ReconcileFirstEvent.call(event:)
      raise result.error if result.failure?
    end
  end
end
