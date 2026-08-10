# frozen_string_literal: true

module Ticketing
  module Exports
    # Invalidates every active export before source-answer erasure commits.
    class InvalidateForEvent < Core::BaseService
      ACTIVE_STATUSES = %w[pending processing ready failed].freeze

      def initialize(event:)
        @event = event
      end

      def call
        AttendeeExport.transaction do
          Core::Database::AdvisoryLock.acquire!("registration-privacy-event", event.id)
          AttendeeExport
            .where(event_id: event.id, status: ACTIVE_STATUSES)
            .includes(:event, :requested_by)
            .lock
            .order(:id)
            .each do |export|
            invalidate!(export)
          end
        end
        success(true)
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.join(", "))
      end

      private

      attr_reader :event

      def invalidate!(export)
        now = Time.current
        export.update!(
          status: "expiring",
          processing_started_at: nil,
          ready_at: nil,
          failed_at: nil,
          failure_code: nil,
          expiring_at: now
        )
        audit_result = Core::Audit::Record.call(
          audit_key: "ticketing-attendee-export-invalidate:#{export.id}",
          action: "ticketing.attendee_export.invalidated",
          auditable_type: export.class.name,
          auditable_id: export.id,
          metadata: { event_id: export.event_id }
        )
        raise audit_result.error if audit_result.failure?

        outbox_result = Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.attendee_export.purge_requested",
          aggregate: export,
          payload: { attendee_export_id: export.id },
          idempotency_key: "attendee-export-purge-requested:#{export.id}"
        )
        raise outbox_result.error if outbox_result.failure?
      end
    end
  end
end
