# frozen_string_literal: true

require "test_helper"

module Ticketing
  class AdmissionConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      @product_access = @product.product_accesses.first
      @event_date = @product_access.event_date
      @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
      @order_item = Orders::OrderItem.find(@ticket.order_item_id)
      @order = @order_item.order
      @assignment = Ticketing::ScannerDeviceAssignment.create!(
        scanner_device: Ticketing::ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "race-scanner-#{SecureRandom.hex(4)}",
          token_digest: Ticketing::ScannerDevice.token_digest_for(token: SecureRandom.hex(32))
        ),
        event: @event,
        assigned_by: @manager
      )
    end

    teardown do
      connection = Ticketing::ApplicationRecord.connection
      # The test removes only its own append-only history rows; temporarily
      # disable those database guards and always restore them below.
      connection.execute(
        "ALTER TABLE ticketing_admission_uses DISABLE TRIGGER trg_ticketing_admission_use_append_only"
      )
      connection.execute(
        "ALTER TABLE ticketing_checkin_logs DISABLE TRIGGER trg_ticketing_checkin_log_append_only"
      )

      begin
        Ticketing::ApplicationRecord.transaction do
          checkin_ids = Ticketing::CheckinLog.where(ticket_id: @ticket.id).select(:id)
          Ticketing::AdmissionUse.where(checkin_log_id: checkin_ids).delete_all
          Ticketing::CheckinLog.where(ticket_id: @ticket.id).delete_all
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
      ensure
        connection.execute(
          "ALTER TABLE ticketing_admission_uses ENABLE TRIGGER trg_ticketing_admission_use_append_only"
        )
        connection.execute(
          "ALTER TABLE ticketing_checkin_logs ENABLE TRIGGER trg_ticketing_checkin_log_append_only"
        )
      end

      @order.update_columns(status: "draft", paid_at: nil)
      Orders::OrderItem.where(id: @order_item.id).delete_all
      Orders::Order.where(id: @order.id).delete_all
      Ticketing::Registration.where(id: @registration.id).delete_all
      Catalog::ProductAccess.where(event_product_id: @product.id).delete_all
      Ticketing::TicketType.where(event_product_id: @product.id).delete_all
      Catalog::EventProduct.where(id: @product.id).delete_all
      Events::EventDate.where(id: @event_date.id).delete_all
    end

    test "only one concurrent single-use scan can consume the slot" do
      claims = Ticketing::Qr::Verifier.call(token: @ticket.current_credential_generation.credentials.first.qr_token).value
      ready = Queue.new
      start = Queue.new
      threads = 2.times.map do
        Thread.new do
          ready << true
          start.pop
          Ticketing::ApplicationRecord.connection_pool.with_connection do
            Ticketing::Admissions::Consume.call(
              claims:,
              product_access: Catalog::ProductAccess.find(@product_access.id),
              assignment: Ticketing::ScannerDeviceAssignment.find(@assignment.id),
              client_scan_id: SecureRandom.uuid,
              scanned_at: @event_date.starts_at + 1.minute,
              lookup_via: "qr",
              identity_check: nil,
              now: @event_date.starts_at + 1.minute
            )
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)

      assert results.all?(&:success?), results.map { |result| result.error&.message }.inspect
      assert_equal [ "duplicate", "success" ], results.map { |result| result.value.result }.sort,
        results.map { |result| result.value.attributes.slice("result", "credential_id", "ticket_id") }.inspect
      assert_equal 1, Ticketing::AdmissionUse.where(product_access: @product_access).count
    ensure
      threads&.each(&:join)
    end
  end
end
