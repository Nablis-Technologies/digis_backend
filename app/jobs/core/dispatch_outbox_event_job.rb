# frozen_string_literal: true

module Core
  # Background wrapper that delivers a single outbox event.
  #
  # Only the event id is enqueued (never the payload), so job arguments stay
  # small and free of sensitive data. Retries back off polynomially and give up
  # after 10 attempts; unrecoverable rows are left for the recovery sweep with an
  # incremented `attempts` counter.
  class DispatchOutboxEventJob < ApplicationJob
    queue_as :outbox
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform(event_id)
      Core::Outbox::Dispatch.call(event_id:)
    end
  end
end
