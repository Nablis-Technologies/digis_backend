# frozen_string_literal: true

module Streaming
  # Closes active sessions after authoritative ticket/event lifecycle changes.
  # Local revocation commits before provider cleanup so provider failures never
  # leave an invalid ticket authorized by Digis.
  class RevokeTicketSessionsJob < ApplicationJob
    queue_as :streaming

    BATCH_SIZE = 100

    def perform(ticket_id: nil, event_id: nil, idempotency_key: nil, now: Time.current)
      Core::IdempotencyKey.new(idempotency_key) if idempotency_key.present?

      loop do
        sessions = revoke_batch(ticket_id:, event_id:, now:)
        break if sessions.empty?

        revoke_provider_playback(sessions)
      end
    end

    private

    def revoke_batch(ticket_id:, event_id:, now:)
      Ticketing::StreamSession.transaction do
        sessions = scoped_sessions(ticket_id:, event_id:)
          .where(status: "active")
          .order(:id)
          .limit(BATCH_SIZE)
          .lock("FOR UPDATE SKIP LOCKED")
          .includes(event_stream: { event_date: :event })
          .to_a
        sessions.each { |session| session.update!(status: "revoked", revoked_at: now) }
        sessions
      end
    end

    def scoped_sessions(ticket_id:, event_id:)
      scope = Ticketing::StreamSession
      scope = scope.where(ticket_id:) if ticket_id.present?
      if event_id.present?
        scope = scope
          .joins(event_stream: :event_date)
          .where(events_event_dates: { event_id: })
      end
      scope
    end

    def revoke_provider_playback(sessions)
      sessions.each do |session|
        Streaming::Providers::Registry.for(session.event_stream).revoke_playback(session:)
      rescue Streaming::Providers::Error
        # The Digis session is already revoked. A later lifecycle retry can
        # attempt provider cleanup without reopening local authorization.
      end
    end
  end
end
