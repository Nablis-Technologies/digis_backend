# frozen_string_literal: true

require "test_helper"

module Ticketing
  class ScannerAdmissionSchemaTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 2)
      @event_date = @product.product_accesses.first.event_date
      @product_access = @product.product_accesses.first
      @credential = @ticket.current_credential_generation.credentials.first
      @zone = @event.access_zones.create!(
        event_date: @event_date,
        type: "venue",
        name: "Main Gate #{SecureRandom.hex(3)}",
        code: "main-#{SecureRandom.hex(3)}"
      )
      @device = ScannerDevice.create!(
        organization: @event.organization,
        device_identifier: "device-#{SecureRandom.hex(6)}",
        token_digest: SecureRandom.hex(32)
      )
      @assignment = ScannerDeviceAssignment.create!(
        scanner_device: @device,
        event: @event,
        assigned_by: @manager
      )
    end

    test "does not use STI for business type columns" do
      assert_empty Events::AccessZone.inheritance_column
      assert_not_includes CheckinLog.column_names, "type"
      assert_not_includes AdmissionUse.column_names, "type"
      assert_not_includes AdmissionUseReversal.column_names, "type"
    end

    test "enforces unique device, active assignment, client scan, and usage identities" do
      duplicate_device = @device.dup
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate_device.save!(validate: false) }

      duplicate_assignment = @assignment.dup
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate_assignment.save!(validate: false) }

      checkin = CheckinLog.create!(checkin_attributes)
      duplicate_scan = checkin.dup
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate_scan.save!(validate: false) }

      use = AdmissionUse.create!(admission_use_attributes(checkin:))
      duplicate_use = use.dup
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate_use.save!(validate: false) }
    end

    test "requires a complete identity override shape and forbids offline overrides" do
      invalid_match = CheckinLog.new(
        checkin_attributes.merge(identity_check_result: "matched")
      )
      assert_not invalid_match.valid?

      invalid_offline_override = CheckinLog.new(
        checkin_attributes.merge(
          scan_upload: ScanUpload.new(
            scanner_device_assignment: @assignment,
            client_upload_id: SecureRandom.uuid,
            received_at: Time.current
          ),
          identity_check_result: "mismatch",
          identity_checked_by: @manager,
          result: "success",
          overrides_checkin_log: CheckinLog.new(checkin_attributes),
          identity_override_by: @manager,
          identity_override_reason: "manager correction",
          identity_overridden_at: Time.current
        )
      )
      assert_not invalid_offline_override.valid?
    end

    test "a reversal group must reverse every use from one successful check-in" do
      checkin = CheckinLog.create!(checkin_attributes)
      first_use = AdmissionUse.create!(admission_use_attributes(
        checkin:,
        admission_slot: @ticket.admission_slots.order(:position).first
      ))
      AdmissionUse.create!(admission_use_attributes(
        checkin:,
        admission_slot: @ticket.admission_slots.order(:position).second,
        usage_number: 1
      ))

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::ApplicationRecord.transaction(requires_new: true) do
          AdmissionUseReversal.create!(reversal_attributes(
            admission_use: first_use,
            checkin_log: checkin,
            reversal_group_id: SecureRandom.uuid
          ))
          Ticketing::ApplicationRecord.connection.execute(
            "SET CONSTRAINTS trg_ticketing_admission_use_reversal_integrity IMMEDIATE"
          )
        end
      end
    end

    test "an assignment zone must belong to the assignment event" do
      other_event = events_events(:draft_concert)
      other_zone = other_event.access_zones.create!(
        type: "venue",
        name: "Other Gate #{SecureRandom.hex(3)}",
        code: "other-#{SecureRandom.hex(3)}"
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::ApplicationRecord.transaction(requires_new: true) do
          ScannerAssignmentZone.create!(
            scanner_device_assignment: @assignment,
            access_zone: other_zone
          )
        end
      end
    end

    test "accepts a complete group reversal without changing historical uses" do
      checkin = CheckinLog.create!(checkin_attributes)
      uses = @ticket.admission_slots.order(:position).map do |slot|
        AdmissionUse.create!(admission_use_attributes(checkin:, admission_slot: slot))
      end
      group_id = SecureRandom.uuid

      Ticketing::ApplicationRecord.transaction do
        uses.each do |use|
          AdmissionUseReversal.create!(reversal_attributes(
            admission_use: use,
            checkin_log: checkin,
            reversal_group_id: group_id
          ))
        end
        Ticketing::ApplicationRecord.connection.execute(
          "SET CONSTRAINTS trg_ticketing_admission_use_reversal_integrity IMMEDIATE"
        )
      end

      assert_equal 2, AdmissionUseReversal.where(reversal_group_id: group_id).count
      assert_equal 2, AdmissionUse.where(checkin_log: checkin).count
    end

    private

    def checkin_attributes(client_scan_id: SecureRandom.uuid, result: "success", **attributes)
      {
        ticket: @ticket,
        credential: @credential,
        credential_version: @ticket.credential_version,
        product_access: @product_access,
        event_date: @event_date,
        scanner_device_assignment: @assignment,
        client_scan_id:,
        result:,
        lookup_via: "qr",
        identity_check_result: "not_required",
        scanned_at: Time.current,
        received_at: Time.current
      }.merge(attributes)
    end

    def admission_use_attributes(checkin:, admission_slot: @ticket.admission_slots.order(:position).first, usage_number: 1)
      {
        admission_slot:,
        product_access: @product_access,
        credential: @credential,
        checkin_log: checkin,
        usage_number:,
        used_at: Time.current
      }
    end

    def reversal_attributes(admission_use:, checkin_log:, reversal_group_id:)
      {
        event: @event,
        admission_use:,
        checkin_log:,
        reversal_group_id:,
        reversed_by: @manager,
        reason_code: "operator_error",
        reversal_version: 1,
        reversed_at: Time.current
      }
    end
  end
end
