# frozen_string_literal: true

module Events
  # Reacts to a committed cancellation by bringing the event's live streams in
  # line with the new (cancelled) schedule. Only the event id is enqueued and
  # the work is idempotent: it stops each still-scheduled stream, which is a
  # no-op once already stopped. No external streaming-provider calls happen here.
  class SyncStreamScheduleJob < ApplicationJob
    queue_as :default

    def perform(event_id)
      event = Events::Event.find_by(id: event_id)
      return unless event

      Events::EventStream
        .joins(:event_date)
        .where(events_event_dates: { event_id: event.id })
        .where.not(status: "ended")
        .update_all(status: "ended", updated_at: Time.current)
    end
  end
end
