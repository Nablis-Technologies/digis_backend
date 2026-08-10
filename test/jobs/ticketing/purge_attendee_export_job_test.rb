# frozen_string_literal: true

require "test_helper"

module Ticketing
  class PurgeAttendeeExportJobTest < ActiveJob::TestCase
    include Ticketing::AttendeeExportTestHelpers

    test "purge outbox delivery enqueues a purge job with only the export id" do
      export = create_export(event: events_events(:ready_listing), actor: core_users(:super_admin), overrides: { status: "expiring" })
      event = Core::Outbox::Publish.call(
        topic: "ticketing",
        event_type: "ticketing.attendee_export.purge_requested",
        aggregate: export,
        payload: { attendee_export_id: export.id },
        idempotency_key: "attendee-export-purge-requested:#{export.id}"
      ).value

      assert_enqueued_with(job: Ticketing::PurgeAttendeeExportJob, args: [ export.id ]) do
        Core::Outbox::Dispatch.call(event_id: event.id)
      end
    end

    test "purges the artifact before writing a payload-free tombstone" do
      export = create_export(
        event: events_events(:ready_listing),
        actor: core_users(:super_admin),
        overrides: { status: "expiring" }
      )
      export.file.attach(io: StringIO.new("private csv"), filename: "export.csv", content_type: "text/csv")

      result = Ticketing::Exports::Purge.call(attendee_export_id: export.id)

      assert_predicate result, :success?, result.error&.message
      assert_equal "expired", export.reload.status
      assert_nil export.field_keys
      assert_nil export.filters
      assert_not export.file.attached?
      assert Core::AuditLog.exists?(
        action: "ticketing.attendee_export.expired",
        auditable_type: export.class.name,
        auditable_id: export.id
      )
    end
  end
end
