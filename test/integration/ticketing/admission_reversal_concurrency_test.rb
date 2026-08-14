# frozen_string_literal: true

require "test_helper"

module Ticketing
  class AdmissionReversalConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      @product_access = @product.product_accesses.first
      @event_date = @product_access.event_date
      @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
      @assignment = create_assignment
      @checkin = consume
    end

    teardown do
      cleanup_admission_history
    end

    test "concurrent managers produce one complete reversal group" do
      ready = Queue.new
      start = Queue.new
      threads = 2.times.map do |index|
        Thread.new do
          ready << true
          start.pop
          Ticketing::ApplicationRecord.connection_pool.with_connection do
            Ticketing::AdmissionUseReversals::Create.call(
              checkin_log: Ticketing::CheckinLog.find(@checkin.id),
              manager: @manager,
              reason_code: "operator_error",
              idempotency_key: "concurrent-reversal-#{index}"
            )
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)

      assert_equal 1, results.count(&:success?)
      assert_equal 1, results.count(&:failure?)
      assert_equal "admission_use_reversal_already_exists", results.find(&:failure?).error.code
      assert_equal 1, AdmissionUseReversal.where(checkin_log_id: @checkin.id).count
    ensure
      threads&.each(&:join)
    end

    private

    def create_assignment
      device = ScannerDevice.create!(
        organization: @event.organization,
        device_identifier: "reversal-race-scanner-#{SecureRandom.hex(4)}",
        token_digest: ScannerDevice.token_digest_for(token: SecureRandom.hex(32))
      )
      ScannerDeviceAssignment.create!(scanner_device: device, event: @event, assigned_by: @manager)
    end

    def consume
      claims = Ticketing::Qr::Verifier.call(
        token: @ticket.current_credential_generation.credentials.first.qr_token
      ).value
      result = Ticketing::Admissions::Consume.call(
        claims:,
        product_access: @product_access,
        assignment: @assignment,
        client_scan_id: SecureRandom.uuid,
        scanned_at: @event_date.starts_at + 1.minute,
        lookup_via: "qr",
        identity_check: nil,
        now: @event_date.starts_at + 1.minute
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end

    def cleanup_admission_history
      connection = Ticketing::ApplicationRecord.connection
      %w[
        trg_ticketing_admission_use_reversal_append_only
        trg_ticketing_checkin_log_append_only
        trg_ticketing_admission_use_append_only
      ].each do |trigger|
        table = trigger.include?("reversal") ? "ticketing_admission_use_reversals" :
          trigger.include?("checkin") ? "ticketing_checkin_logs" : "ticketing_admission_uses"
        connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}")
      end

      Ticketing::ApplicationRecord.transaction do
        reversal_ids = Ticketing::AdmissionUseReversal.where(checkin_log_id: @checkin.id).pluck(:id)
        Ticketing::AdmissionUseReversal.where(checkin_log_id: @checkin.id).delete_all
        Ticketing::AdmissionUse.where(checkin_log_id: @checkin.id).delete_all
        Ticketing::CheckinLog.where(id: @checkin.id).delete_all
        Core::AuditLog.where(auditable_id: reversal_ids).delete_all
        Core::OutboxEvent.where(aggregate_id: @event.id).delete_all

        Ticketing::ScannerAssignmentZone.where(
          scanner_device_assignment_id: @assignment.id
        ).delete_all
        Ticketing::ScannerDeviceAssignment.where(id: @assignment.id).delete_all
        Ticketing::ScannerDevice.where(id: @assignment.scanner_device_id).delete_all

        credential_ids = Ticketing::Credential.where(ticket_id: @ticket.id).select(:id)
        Ticketing::CredentialRevocation.where(credential_id: credential_ids).delete_all
        Ticketing::AttendeeIndexEntry.where(ticket_id: @ticket.id).delete_all
        Ticketing::Credential.where(ticket_id: @ticket.id).delete_all
        @ticket.update_columns(current_credential_generation_id: nil)
        Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).delete_all
        Ticketing::AdmissionSlot.where(ticket_id: @ticket.id).delete_all
        Ticketing::Revocation.where(ticket_id: @ticket.id).delete_all
        Ticketing::TicketSuspension.where(ticket_id: @ticket.id).delete_all
        Ticketing::TicketTransfer.where(ticket_id: @ticket.id).delete_all
        Core::OutboxEvent.where(aggregate_id: @ticket.id).delete_all
        Ticketing::Ticket.where(id: @ticket.id).delete_all
      end

      order_item = Orders::OrderItem.find(@ticket.order_item_id)
      order = order_item.order
      order.update_columns(status: "draft", paid_at: nil)
      Orders::OrderItem.where(id: order_item.id).delete_all
      Orders::Order.where(id: order.id).delete_all
      Ticketing::Registration.where(id: @registration.id).delete_all
      Catalog::ProductAccess.where(event_product_id: @product.id).delete_all
      Ticketing::TicketType.where(event_product_id: @product.id).delete_all
      Catalog::EventProduct.where(id: @product.id).delete_all
      Events::EventDate.where(id: @event_date.id).delete_all
    ensure
      connection.execute(
        "ALTER TABLE ticketing_admission_use_reversals ENABLE TRIGGER trg_ticketing_admission_use_reversal_append_only"
      )
      connection.execute(
        "ALTER TABLE ticketing_checkin_logs ENABLE TRIGGER trg_ticketing_checkin_log_append_only"
      )
      connection.execute(
        "ALTER TABLE ticketing_admission_uses ENABLE TRIGGER trg_ticketing_admission_use_append_only"
      )
    end
  end
end
