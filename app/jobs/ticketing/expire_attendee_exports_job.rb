# frozen_string_literal: true

module Ticketing
  # Claims a bounded set of due or stuck-expiring exports for retry-safe purge.
  class ExpireAttendeeExportsJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = 100
    STATUSES = %w[pending processing ready failed expiring].freeze

    def perform(limit = BATCH_SIZE)
      export_ids = due_export_ids(limit)
      export_ids.each { |export_id| Ticketing::Exports::Expire.call(attendee_export_id: export_id) }
    end

    private

    def due_export_ids(limit)
      batch_limit = limit.to_i.clamp(1, BATCH_SIZE)
      Ticketing::AttendeeExport.transaction do
        Ticketing::AttendeeExport
          .where(status: STATUSES)
          .where("status = :expiring OR expires_at <= :now", expiring: "expiring", now: Time.current)
          .order(:expires_at, :id)
          .limit(batch_limit)
          .lock("FOR UPDATE SKIP LOCKED")
          .pluck(:id)
      end
    end
  end
end
