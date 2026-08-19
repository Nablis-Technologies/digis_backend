# frozen_string_literal: true

module Streaming
  # Marks expired Digis sessions in bounded, lock-skipping batches. Provider
  # grants are already bounded by the session/window expiry and are not
  # refreshed by this job.
  class ExpireSessionsJob < ApplicationJob
    queue_as :streaming

    BATCH_SIZE = 100

    def perform(now: Time.current)
      expire_batch(now:)
    end

    private

    def expire_batch(now:)
      Ticketing::StreamSession.transaction do
        sessions = Ticketing::StreamSession
          .where(status: "active")
          .where("expires_at <= ?", now)
          .order(:id)
          .limit(BATCH_SIZE)
          .lock("FOR UPDATE SKIP LOCKED")
          .to_a
        sessions.each { |session| session.update!(status: "expired") }
        sessions
      end
    end
  end
end
