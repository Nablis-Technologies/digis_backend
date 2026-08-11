# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Exports
    class GenerateTest < ActiveSupport::TestCase
      include Ticketing::AttendeeExportTestHelpers

      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @ticket_type = create_export_ticket_type(@event)
        @registration = create_export_registration(@event, @ticket_type)
      end

      test "generates deterministic private CRLF CSV with checksum, count, and formula neutralization" do
        answer, selector = create_export_answer(registration: @registration)
        export = create_export(
          event: @event,
          actor: @actor,
          overrides: {
            field_keys: [ "registration_id", "registration_status", selector ],
            data_cutoff_at: 1.minute.from_now
          }
        )

        result = Generate.call(attendee_export_id: export.id)

        assert_predicate result, :success?, result.error&.message
        export.reload
        assert_equal "ready", export.status
        assert_equal 1, export.row_count
        assert_equal "text/csv", export.file.blob.content_type
        assert_equal Digest::SHA256.hexdigest(export.file.download), export.file_sha256
        assert_equal "private_exports", export.file.blob.service_name
        assert Core::AuditLog.exists?(
          action: "ticketing.attendee_export.ready",
          auditable_type: export.class.name,
          auditable_id: export.id
        )
        assert_includes export.file.download, "\r\n"
        assert_includes export.file.download, "'=2+2"
        assert answer.reload.effective_answer.present?
      end

      test "uses cutoff-bounded answers but current status and contact values" do
        @registration.update!(status: "cancelled")
        @registration.update_columns(created_at: 3.hours.ago, updated_at: Time.current)
        @registration.user.update!(email: "current-contact@example.com")
        answer, selector = create_export_answer(
          registration: @registration,
          value: "Original",
          answered_at: 2.hours.ago
        )
        answer.revisions.create!(
          revision_number: 1,
          answer: "Future correction",
          revised_by: @actor,
          source: "manager_correction",
          reason_code: "data_quality",
          idempotency_key_digest: SecureRandom.hex(32),
          request_digest: SecureRandom.hex(32),
          revised_at: 1.hour.ago
        )
        export = create_export(
          event: @event,
          actor: @actor,
          overrides: {
            field_keys: [ "registration_status", "registration_user_email", selector ],
            data_cutoff_at: 90.minutes.ago
          }
        )

        result = Generate.call(attendee_export_id: export.id)

        assert_predicate result, :success?, result.error&.message
        row = CSV.parse(export.reload.file.download, headers: true).first
        assert_equal "cancelled", row["Registration Status"]
        assert_equal "current-contact@example.com", row["Registration User Email"]
        assert_equal "Original", row["Formula"]
      end

      test "generates one row for every admission coordinate" do
        ticket_type = create_export_ticket_type(@event, admissions_per_unit: 2)
        registration = create_export_registration(@event, ticket_type, package_quantity: 2)
        export = create_export(
          event: @event,
          actor: @actor,
          overrides: {
            row_mode: "admission",
            field_keys: [ "registration_id", "package_unit_number", "admission_position" ],
            filters: { "ticket_type_ids" => [ ticket_type.id ] }
          }
        )
        registration.update_columns(created_at: 1.minute.ago)

        result = Generate.call(attendee_export_id: export.id)

        assert_predicate result, :success?, result.error&.message
        assert_equal 4, export.reload.row_count
      end

      test "shortens expiry to the earliest represented retention deadline" do
        answer, selector = create_export_answer(
          registration: @registration,
          value: "Retained briefly",
          answered_at: 23.hours.ago,
          retention_days: 1
        )
        export = create_export(
          event: @event,
          actor: @actor,
          overrides: { field_keys: [ selector ], data_cutoff_at: Time.current }
        )

        result = Generate.call(attendee_export_id: export.id)

        assert_predicate result, :success?, result.error&.message
        assert_operator export.reload.expires_at, :<=, answer.retain_until
      end

      test "purges an existing partial file when the attempt budget is exhausted" do
        export = create_export(
          event: @event,
          actor: @actor,
          overrides: {
            status: "processing",
            attempt_count: 3,
            processing_started_at: 16.minutes.ago
          }
        )
        export.file.attach(io: StringIO.new("partial"), filename: "partial.csv", content_type: "text/csv")

        result = Generate.call(attendee_export_id: export.id)

        assert_predicate result, :success?, result.error&.message
        assert_equal "failed", export.reload.status
        assert_not export.file.attached?
      end

      test "reclaims a stale processing lease and refuses a fourth attempt" do
        stale = create_export(
          event: @event,
          actor: @actor,
          overrides: {
            status: "processing",
            attempt_count: 1,
            processing_started_at: 16.minutes.ago
          }
        )

        result = Generate.call(attendee_export_id: stale.id)

        assert_predicate result, :success?, result.error&.message
        assert_equal "ready", stale.reload.status
        assert_equal 2, stale.attempt_count

        exhausted = create_export(
          event: @event,
          actor: @actor,
          overrides: {
            status: "processing",
            attempt_count: 3,
            processing_started_at: 16.minutes.ago
          }
        )
        exhausted_result = Generate.call(attendee_export_id: exhausted.id)

        assert_predicate exhausted_result, :success?, exhausted_result.error&.message
        assert_equal "failed", exhausted.reload.status
        assert_equal "export_generation_failed", exhausted.failure_code
      end

      test "does not finalize after current export authorization is lost" do
        export = create_export(event: @event, actor: @actor)
        Ticketing::AttendeeExportPolicy.any_instance.stubs(:create?).returns(false)

        result = Generate.call(attendee_export_id: export.id)

        assert_predicate result, :success?, result.error&.message
        assert_equal "failed", export.reload.status
        assert_equal "export_generation_failed", export.failure_code
        assert Core::AuditLog.exists?(
          action: "ticketing.attendee_export.generation_failed",
          auditable_type: export.class.name,
          auditable_id: export.id
        )
      end
    end
  end
end
