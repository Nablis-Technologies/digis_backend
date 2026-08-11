# frozen_string_literal: true

module Ticketing
  module Exports
    # Removes the private artifact, then commits the digest-only tombstone.
    class Purge < Core::BaseService
      def initialize(attendee_export_id:)
        @attendee_export_id = attendee_export_id
      end

      def call
        export = AttendeeExport.find(@attendee_export_id)
        return success(export) unless export.status == "expiring"

        export.file.purge if export.file.attached?
        AttendeeExport.transaction do
          Core::Database::AdvisoryLock.acquire!("registration-privacy-event", export.event_id)
          locked = AttendeeExport.lock.find(@attendee_export_id)
          return success(locked) unless locked.status == "expiring"

          locked.update!(
            status: "expired",
            field_keys: nil,
            filters: nil,
            failure_code: nil,
            expiring_at: nil,
            expired_at: Time.current
          )
          record_audit(locked)
          success(locked)
        end
      end

      private

      def record_audit(export)
        result = Core::Audit::Record.call(
          audit_key: "ticketing-attendee-export-expire:#{export.id}",
          action: "ticketing.attendee_export.expired",
          auditable_type: export.class.name,
          auditable_id: export.id,
          metadata: { event_id: export.event_id }
        )
        raise result.error if result.failure?
      end
    end
  end
end
