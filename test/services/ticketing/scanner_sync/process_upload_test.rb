# frozen_string_literal: true

require "test_helper"

module Ticketing
  module ScannerSync
    class ProcessUploadTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        @product_access = @product.product_accesses.first
        @event_date = @product_access.event_date
        @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
        @assignment = build_scanner_assignment(
          event: @event,
          assigned_by: @manager,
          device_identifier: "upload-scanner-#{SecureRandom.hex(4)}"
        )
        @device = @assignment.scanner_device
      end

      test "replaying a completed upload returns its exact stored response" do
        scan = scan_attributes
        first = process_upload(scans: [ scan ])
        @event.update_columns(schedule_version: @event.schedule_version + 1)

        replay = process_upload(scans: [ scan ])

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert_equal first.value, replay.value
        assert_equal 1, Ticketing::ScanUpload.where(client_upload_id: @upload_id).count
        assert_equal 1, Ticketing::CheckinLog.where(client_scan_id: scan[:client_scan_id]).count

        upload = Ticketing::ScanUpload.find_by!(client_upload_id: @upload_id)
        assert_raises(ActiveRecord::RecordInvalid) do
          upload.update!(results_snapshot: { "results" => [] })
        end
      end

      test "replaying a scan from a different upload returns the stored result" do
        scan = scan_attributes
        first = process_upload(scans: [ scan ])

        second = process_upload(
          client_upload_id: SecureRandom.uuid,
          scans: [ scan ]
        )

        assert_equal first.value.fetch("results"), second.value.fetch("results")
        assert_equal 1, Ticketing::CheckinLog.where(client_scan_id: scan[:client_scan_id]).count
        assert_equal 2, Ticketing::AdmissionUse.where(product_access: @product_access).count
      end

      test "an interrupted upload can be resumed without duplicating its scan" do
        first_scan = scan_attributes
        second_scan = scan_attributes
        upload = Ticketing::ScanUpload.create!(
          scanner_device_assignment: @assignment,
          client_upload_id: SecureRandom.uuid,
          received_at: Time.current
        )
        Ticketing::Admissions::Consume.call(
          claims: current_claims,
          product_access: @product_access,
          assignment: @assignment,
          client_scan_id: first_scan[:client_scan_id],
          scanned_at: first_scan[:scanned_at],
          lookup_via: "qr",
          now: first_scan[:scanned_at]
        )
        upload.update!(results_snapshot: { "results" => [ { "client_scan_id" => first_scan[:client_scan_id] } ] })

        result = ProcessUpload.call(
          assignment: @assignment,
          operator: @manager,
          client_upload_id: upload.client_upload_id,
          scans: [ first_scan, second_scan ],
          cursors: zero_cursors
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal 2, result.value.fetch("results").length
        assert_equal 2, Ticketing::CheckinLog.where(ticket: @ticket).count
      end

      test "two offline scans claiming one bounded slot produce one winner" do
        first = process_upload(client_upload_id: SecureRandom.uuid, scans: [ scan_attributes ])
        second = process_upload(client_upload_id: SecureRandom.uuid, scans: [ scan_attributes ])

        assert_equal "success", first.value.fetch("results").sole.fetch("result")
        assert_equal "duplicate", second.value.fetch("results").sole.fetch("result")
        assert_equal 1, Ticketing::CheckinLog.where(ticket: @ticket, result: "success").count
        assert_equal 1, Ticketing::CheckinLog.where(ticket: @ticket, result: "duplicate").count
        assert_equal @ticket.admission_slots.count,
          Ticketing::AdmissionUse.where(product_access: @product_access).count
      end

      test "stale or revoked scans return authoritative conflict results" do
        credential = @ticket.current_credential_generation.credentials.first
        credential.update_columns(status: "revoked", revoked_at: Time.current)

        result = process_upload(scans: [ scan_attributes ])

        assert_equal "revoked", result.value.fetch("results").sole.fetch("result")
        assert_empty Ticketing::AdmissionUse.where(product_access: @product_access)
      end

      test "a revoked generation returns an authoritative conflict result" do
        generation = @ticket.current_credential_generation
        generation.update_columns(status: "revoked", revoked_at: Time.current)

        result = process_upload(scans: [ scan_attributes ])

        assert_equal "revoked", result.value.fetch("results").sole.fetch("result")
        assert_empty Ticketing::AdmissionUse.where(product_access: @product_access)
      end

      test "a suspended package returns an authoritative conflict result" do
        suspension = Ticketing::Suspensions::Open.call(
          ticket: @ticket,
          actor: @manager,
          reason_code: "suspected_fraud",
          review_deadline_at: 3.days.from_now,
          idempotency_key: "offline-suspension-#{SecureRandom.hex(8)}"
        )
        assert_predicate suspension, :success?, suspension.error&.message

        result = process_upload(scans: [ scan_attributes ])

        assert_equal "revoked", result.value.fetch("results").sole.fetch("result")
        assert_empty Ticketing::AdmissionUse.where(product_access: @product_access)
      end

      test "wrong-zone scans are logged without consuming a slot" do
        zone = @event.access_zones.create!(
          event_date: @event_date,
          type: "venue",
          name: "Upload gate",
          code: "upload-zone-#{SecureRandom.hex(4)}",
          active: true,
          sort_order: 1
        )
        @product_access.product_access_zones.create!(access_zone: zone)

        result = process_upload(scans: [ scan_attributes(access_zone_id: zone.id) ])

        assert_equal "wrong_zone", result.value.fetch("results").sole.fetch("result")
        assert_empty Ticketing::AdmissionUse.where(product_access: @product_access)
      end

      test "a credential submitted for a different ticket is rejected" do
        result = process_upload(scans: [ scan_attributes(ticket_id: SecureRandom.uuid) ])

        assert_predicate result, :failure?
        assert_equal "scan_upload_credential_mismatch", result.error.code
        assert_empty Ticketing::CheckinLog.where(ticket: @ticket)
      end

      test "does not trust an offline identity checker from another operator" do
        result = process_upload(
          scans: [ scan_attributes(identity_check_result: "matched", identity_checked_by_id: @other_user.id) ]
        )

        assert_predicate result, :failure?
        assert_equal "identity_checker_mismatch", result.error.code
        assert_empty Ticketing::CheckinLog.where(ticket: @ticket)
      end

      test "an empty heartbeat returns the current sync delta" do
        result = process_upload(scans: [])

        assert_predicate result, :success?, result.error&.message
        assert_equal "delta", result.value.fetch("sync").fetch("sync_mode")
        assert_empty result.value.fetch("results")
        %w[
          package_revocations credential_revocations attendee_index schedule
          server_use_ids admission_use_reversals
        ].each do |feed|
          assert result.value.fetch("sync").key?(feed), "missing #{feed} feed"
        end
      end

      private

      def process_upload(client_upload_id: @upload_id ||= SecureRandom.uuid, scans:)
        ProcessUpload.call(
          assignment: @assignment,
          operator: @manager,
          client_upload_id:,
          scans:,
          cursors: zero_cursors
        )
      end

      def scan_attributes(
        access_zone_id: nil, ticket_id: @ticket.id, identity_check_result: "not_required",
        identity_checked_by_id: nil
      )
        credential = @ticket.current_credential_generation.credentials.first
        {
          credential_id: credential.id,
          ticket_id:,
          credential_version: credential.credential_generation.version,
          product_access_id: @product_access.id,
          access_zone_id:,
          client_scan_id: SecureRandom.uuid,
          scanned_at: @event_date.starts_at + 1.minute,
          result: "success",
          lookup_via: "qr",
          identity_check_result:,
          identity_checked_by_id:
        }.compact
      end

      def current_claims
        Ticketing::Qr::Verifier.call(
          token: @ticket.current_credential_generation.credentials.first.qr_token
        ).value
      end

      def zero_cursors
        { revocations: 0, attendee_index: 0, schedule: 0, reversals: 0 }
      end
    end
  end
end
