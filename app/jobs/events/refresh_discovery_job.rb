# frozen_string_literal: true

module Events
  # Recomputes an event's public-discovery eligibility after a state change.
  # Pre-launch there is no external search index, so this records the last
  # refresh timestamp; later discovery queries can order/filter on it. The job
  # is idempotent and safe to retry.
  class RefreshDiscoveryJob < ApplicationJob
    queue_as :default

    def perform(event_id)
      event = Events::Event.find_by(id: event_id)
      return unless event
      return unless event.status == "published"

      event.update_column(:discovery_refreshed_at, Time.current)
    end
  end
end
