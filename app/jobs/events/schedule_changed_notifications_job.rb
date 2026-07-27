# frozen_string_literal: true

module Events
  # Reacts to a committed schedule change. Only the event id is enqueued and the
  # work is safe to run more than once. A schedule change edits specific dates
  # (exceptions) and must NOT re-materialize the recurrence series — that is
  # owned by recurrence-rule configuration/activation only. Notification/stream
  # fan-out is handled elsewhere; this job no longer triggers recurrence
  # materialization.
  class ScheduleChangedNotificationsJob < ApplicationJob
    queue_as :default

    def perform(event_id)
      # Intentionally a no-op after decoupling from recurrence materialization.
      # Kept as an extension point for schedule-change side effects.
    end
  end
end
