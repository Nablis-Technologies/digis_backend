# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Admissions
    class ConsumeTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 3)
        @product_access = @product.product_accesses.first
        @event_date = @product_access.event_date
        @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
        @device = Ticketing::ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "consume-scanner-#{SecureRandom.hex(4)}",
          token_digest: Ticketing::ScannerDevice.token_digest_for(token: SecureRandom.hex(32))
        )
        @assignment = Ticketing::ScannerDeviceAssignment.create!(
          scanner_device: @device,
          event: @event,
          assigned_by: @manager
        )
      end

      test "group scan consumes every slot atomically" do
        result = consume

        assert_predicate result, :success?, result.error&.message
        assert_equal "success", result.value.result
        assert_equal 3, result.value.admission_uses.count
        assert_equal [ 1, 1, 1 ], result.value.admission_uses.order(:admission_slot_id).map(&:usage_number)
      end

      test "bounded access records a duplicate without consuming a second time" do
        first = consume
        second = consume

        assert_equal "success", first.value.result
        assert_equal "duplicate", second.value.result
        assert_empty second.value.admission_uses
        assert_equal 3, Ticketing::AdmissionUse.where(product_access: @product_access).count
      end

      test "replaying a client scan returns the stored immutable attempt" do
        client_scan_id = SecureRandom.uuid
        first = consume(client_scan_id:)
        replay = consume(client_scan_id:)

        assert_equal first.value.id, replay.value.id
        assert_equal first.value.result, replay.value.result
        assert_equal 1, Ticketing::CheckinLog.where(client_scan_id:).count
        assert_equal 3, Ticketing::AdmissionUse.where(product_access: @product_access).count
      end

      test "unlimited access allocates the next historical usage number" do
        @product_access.update!(usage_limit: nil)

        first = consume
        second = consume

        assert_equal "success", first.value.result
        assert_equal "success", second.value.result
        assert_equal [ 1, 2 ], Ticketing::AdmissionUse.where(
          admission_slot: @ticket.admission_slots.order(:position).first,
          product_access: @product_access
        ).order(:usage_number).pluck(:usage_number)
      end

      test "outside-window scans are logged without consuming slots" do
        result = consume(now: @event_date.starts_at - 1.minute)

        assert_equal "wrong_date", result.value.result
        assert_empty result.value.admission_uses
        assert_empty Ticketing::AdmissionUse.where(product_access: @product_access)
      end

      test "wrong-zone scans are logged without consuming slots" do
        zone = @event.access_zones.create!(
          event_date: @event_date,
          type: "venue",
          name: "Unassigned gate",
          code: "unassigned-#{SecureRandom.hex(4)}",
          active: true,
          sort_order: 1
        )

        result = consume(access_zone: zone)

        assert_equal "wrong_zone", result.value.result
        assert_empty result.value.admission_uses
        assert_empty Ticketing::AdmissionUse.where(product_access: @product_access)
      end

      test "individually revoked credentials are recorded as revoked" do
        credential = @ticket.current_credential_generation.credentials.first
        credential.update_columns(status: "revoked", revoked_at: Time.current)

        result = consume

        assert_equal "revoked", result.value.result
        assert_empty result.value.admission_uses
        assert_empty Ticketing::AdmissionUse.where(product_access: @product_access)
      end

      test "rejects admission after the event is cancelled" do
        @event.update!(status: "cancelled")

        result = consume

        assert_predicate result, :failure?
        assert_equal "event_cancelled", result.error.code
        assert_empty Ticketing::AdmissionUse.where(product_access: @product_access)
      end

      private

      def consume(access_zone: nil, now: @event_date.starts_at + 1.minute, client_scan_id: SecureRandom.uuid)
        Ticketing::Admissions::Consume.call(
          claims: current_claims,
          product_access: @product_access,
          assignment: @assignment,
          access_zone:,
          client_scan_id:,
          scanned_at: now,
          lookup_via: "qr",
          identity_check: nil,
          now:
        )
      end

      def current_claims
        Ticketing::Qr::Verifier.call(token: @ticket.current_credential_generation.credentials.first.qr_token).value
      end
    end
  end
end
