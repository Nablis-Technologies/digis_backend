# frozen_string_literal: true

require "test_helper"

module Ticketing
  module ManualLookup
    class ByCodeTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        prepare_scanner_lookup
      end

      test "validates the PNR, consumes through the shared admission service, and audits the reason" do
        result = lookup

        assert_predicate result, :success?, result.error&.message
        assert_equal "success", result.value.status
        assert_equal "code", result.value.checkin.lookup_via
        assert_equal "no_qr_printout", result.value.checkin.reason_code
        assert Core::AuditLog.exists?(
          action: "ticketing.scanner.manual_lookup",
          auditable_type: Ticketing::ScannerDeviceAssignment.name,
          auditable_id: @assignment.id
        )
      end

      test "rejects an invalid PNR check digit before querying the index" do
        result = lookup(raw_code: "22222223")

        assert_predicate result, :failure?
        assert_equal "invalid_lookup_code", result.error.code
        assert_empty Ticketing::CheckinLog.where(scanner_device_assignment: @assignment)
      end

      test "returns not found for a valid but unknown PNR" do
        unknown = Core::LookupCodeService.generate(@event.id, reserved_codes: [ @entry.lookup_code ])

        result = lookup(raw_code: unknown)

        assert_predicate result, :failure?
        assert_equal "lookup_not_found", result.error.code
      end

      private

      def prepare_scanner_lookup
        @product_access = @product.product_accesses.first
        @event_date = @product_access.event_date
        @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
        @entry = @ticket.current_credential_generation.credentials.first.attendee_index_entry
        @assignment = build_scanner_assignment(
          event: @event,
          assigned_by: @manager,
          device_identifier: "manual-code-#{SecureRandom.hex(4)}"
        )
        @device = @assignment.scanner_device
      end

      def lookup(raw_code: @entry.lookup_code)
        ByCode.call(
          raw_code:,
          event: @event,
          product_access: @product_access,
          assignment: @assignment,
          operator: @manager,
          reason_code: "no_qr_printout",
          client_scan_id: SecureRandom.uuid,
          scanned_at: @event_date.starts_at + 1.minute
        )
      end
    end
  end
end
