# frozen_string_literal: true

require "test_helper"

module Ticketing
  class GenerateAttendeeExportJobTest < ActiveJob::TestCase
    include Ticketing::AttendeeExportTestHelpers

    test "passes only the export id to generation" do
      export = create_export(event: events_events(:ready_listing), actor: core_users(:super_admin))
      Ticketing::Exports::Generate.expects(:call).with(attendee_export_id: export.id)

      Ticketing::GenerateAttendeeExportJob.perform_now(export.id)
    end

    test "requested outbox delivery enqueues generation with only the export id" do
      export = Ticketing::AttendeeExport.new(
        event: events_events(:ready_listing),
        requested_by: core_users(:super_admin),
        status: "pending",
        row_mode: "registration",
        format_version: "csv_v1",
        field_keys: [ "registration_id" ],
        filters: {},
        field_set_digest: "a" * 64,
        filter_digest: "b" * 64,
        reason_code: "event_operations",
        data_cutoff_at: Time.current,
        expires_at: 1.hour.from_now,
        idempotency_key_digest: "c" * 64,
        request_fingerprint: "d" * 64,
        digest_key_version: "v1",
        attempt_count: 0,
        lock_version: 0
      )
      export.save!
      outbox = Core::Outbox::Publish.call(
        topic: "ticketing",
        event_type: "ticketing.attendee_export.requested",
        aggregate: export,
        payload: { attendee_export_id: export.id },
        idempotency_key: "attendee-export-requested:#{export.id}"
      ).value

      assert_enqueued_with(job: Ticketing::GenerateAttendeeExportJob, args: [ export.id ]) do
        dispatch = -> { 2.times { Core::Outbox::Dispatch.call(event_id: outbox.id) } }
        defined?(Prosopite) ? Prosopite.pause(&dispatch) : dispatch.call
      end
    end
  end
end
