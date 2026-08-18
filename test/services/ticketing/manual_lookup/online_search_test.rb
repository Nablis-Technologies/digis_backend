# frozen_string_literal: true

require "test_helper"

module Ticketing
  module ManualLookup
    class OnlineSearchTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        @product_access = @product.product_accesses.first
        @event_date = @product_access.event_date
        @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
        @entry = @ticket.current_credential_generation.credentials.first.attendee_index_entry
        @device = Ticketing::ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "manual-online-#{SecureRandom.hex(4)}",
          token_digest: Ticketing::ScannerDevice.token_digest_for(token: SecureRandom.hex(32))
        )
        @assignment = Ticketing::ScannerDeviceAssignment.create!(
          scanner_device: @device,
          event: @event,
          assigned_by: @manager
        )
      end

      test "returns minimal matches and records a search audit" do
        result = search(query: @owner.phone)

        assert_predicate result, :success?, result.error&.message
        assert_equal "matches", result.value.status
        assert_equal [ @entry.credential_id.to_s ], result.value.matches.map { |match| match.fetch(:credential_id).to_s }
        assert result.value.matches.first.key?(:lookup_code)
        refute result.value.matches.first.key?(:phone_hash)
        assert Core::AuditLog.exists?(
          action: "ticketing.scanner.manual_lookup",
          auditable_id: @assignment.id
        )
      end

      test "does not allow an ordinary scanner to use online help-desk search" do
        Events::EventStaffAssignment.create!(
          event: @event,
          user: @other_user,
          organization: @event.organization,
          role: "scanner",
          status: "active"
        )

        result = search(query: @owner.phone, operator: @other_user)

        assert_predicate result, :failure?
        assert_equal "help_desk_forbidden", result.error.code
      end

      private

      def search(query:, operator: @manager)
        OnlineSearch.call(
          query:,
          event: @event,
          assignment: @assignment,
          operator:,
          reason_code: "no_qr_printout",
          request_id: SecureRandom.uuid
        )
      end
    end
  end
end
