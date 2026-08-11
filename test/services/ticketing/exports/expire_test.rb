# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Exports
    class ExpireTest < ActiveSupport::TestCase
      include Ticketing::AttendeeExportTestHelpers

      test "purges a due artifact before writing a payload-free tombstone" do
        export = create_due_export(status: "ready")
        export.file.attach(io: StringIO.new("private csv"), filename: "export.csv", content_type: "text/csv")

        result = Expire.call(attendee_export_id: export.id)

        assert_predicate result, :success?, result.error&.message
        assert_equal "expired", export.reload.status
        assert_nil export.field_keys
        assert_nil export.filters
        assert_nil export.failure_code
        assert_not export.file.attached?
        assert Core::AuditLog.exists?(
          action: "ticketing.attendee_export.expired",
          auditable_type: export.class.name,
          auditable_id: export.id
        )
      end

      test "retries a stuck expiring export" do
        export = create_due_export(status: "expiring")
        export.file.attach(io: StringIO.new("partial csv"), filename: "export.csv", content_type: "text/csv")

        result = Expire.call(attendee_export_id: export.id)

        assert_predicate result, :success?, result.error&.message
        assert_equal "expired", export.reload.status
        assert_not export.file.attached?
      end

      test "is idempotent after the tombstone has been written" do
        export = create_due_export(status: "ready")
        export.file.attach(io: StringIO.new("private csv"), filename: "export.csv", content_type: "text/csv")

        assert_audit_idempotent(
          -> { Expire.call(attendee_export_id: export.id) },
          action: "ticketing.attendee_export.expired",
          auditable_type: export.class.name,
          auditable_id: export.id
        )
      end

      private

      def create_due_export(status:)
        create_export(
          event: events_events(:ready_listing),
          actor: core_users(:super_admin),
          overrides: {
            status:,
            data_cutoff_at: 2.days.ago,
            expires_at: 1.minute.ago
          }
        )
      end
    end
  end
end
