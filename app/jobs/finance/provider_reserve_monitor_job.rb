# frozen_string_literal: true

module Finance
  # Periodically observes provider reserve state. The service owns transition
  # deduplication and keeps this job safe to retry or run concurrently.
  class ProviderReserveMonitorJob < ApplicationJob
    queue_as :default

    def perform
      Finance::MonitorProviderReserves.call
    end
  end
end
