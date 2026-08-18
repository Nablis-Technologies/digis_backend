# frozen_string_literal: true

require "test_helper"

module Ticketing
  class CancelPaidPackageTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 2)
      @payment = create_payment_for(@ticket.order_item)
    end

    test "suspends an unused paid package before creating its refund" do
      result = CancelPaidPackage.call(
        ticket: @ticket,
        actor: @manager,
        idempotency_key: "cancel-package-#{SecureRandom.hex(8)}"
      )

      assert_predicate result, :success?, result.error&.message
      refund = result.value

      assert_equal "created", refund.status
      assert_equal "active", @ticket.reload.status
      assert @ticket.package_suspended?
      assert_not @ticket.package_dead?
      assert_equal 1, Ticketing::TicketSuspension.where(ticket: @ticket, status: "active").count
      assert_equal @ticket.id, refund.refund_items.sole.ticket_id
      assert_equal "organizer_ticket_cancellation", refund.reason_code
    end

    test "finishes the package only after a successful provider refund event" do
      refund = cancel_package
      refund.update!(status: "processing")

      applied = Orders::ApplyRefundResult.call(
        refund:,
        result: Payments::Providers::Result.success(provider_reference: "refund-#{SecureRandom.hex(4)}")
      )

      assert_predicate applied, :success?, applied.error&.message
      event = Core::OutboxEvent.find_by!(event_type: "orders.refund.succeeded")
      dispatched = Core::Outbox::Dispatch.call(event_id: event.id)

      assert_predicate dispatched, :success?, dispatched.error&.message
      assert_equal "refunded", @ticket.reload.status
      assert @ticket.package_dead?
      assert_not @ticket.package_suspended?
      assert_equal "cancelled_refunded", @ticket.ticket_suspensions.order(:created_at).last.status
      assert_equal "revoked", @ticket.current_credential_generation.reload.status
      assert Core::OutboxEvent.exists?(
        event_type: "ticketing.package_refunded", aggregate_id: @ticket.id
      )
    end

    test "keeps the package suspended while funds are pending" do
      refund = cancel_package
      refund.update!(status: "pending_funds", pending_reason: "insufficient_funds")

      assert_equal "active", @ticket.reload.status
      assert @ticket.package_suspended?
      assert_not @ticket.package_dead?
      assert_equal "active", @ticket.ticket_suspensions.active.sole.status
    end

    test "keeps a failed package refund suspended and replayable" do
      refund = cancel_package
      refund.update!(status: "processing")

      applied = Orders::ApplyRefundResult.call(
        refund:,
        result: Payments::Providers::Result.failure(failure_code: "declined")
      )

      assert_predicate applied, :success?, applied.error&.message
      event = Core::OutboxEvent.find_by!(event_type: "orders.refund.failed")
      dispatched = Core::Outbox::Dispatch.call(event_id: event.id)

      assert_predicate dispatched, :success?, dispatched.error&.message
      assert_equal "active", @ticket.reload.status
      assert @ticket.package_suspended?
      assert_not @ticket.package_dead?
      assert_equal "active", @ticket.ticket_suspensions.active.sole.status
    end

    test "rejects a used paid package without an audited override" do
      consume_package

      result = CancelPaidPackage.call(
        ticket: @ticket,
        actor: @manager,
        idempotency_key: "cancel-used-package-#{SecureRandom.hex(8)}"
      )

      assert_predicate result, :failure?
      assert_equal "package_used", result.error.code
      assert_empty Orders::Refund.where(payment: @payment)
    end

    test "allows a platform override for a used package and audits the exception" do
      consume_package

      result = CancelPaidPackage.call(
        ticket: @ticket,
        actor: @manager,
        idempotency_key: "cancel-used-override-#{SecureRandom.hex(8)}",
        override_reason: "Legal remedy required for the affected attendee."
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal 1, Core::AuditLog.where(
        auditable_type: "Ticketing::Ticket",
        auditable_id: @ticket.id,
        action: "ticketing.package_refund.used_override"
      ).count
    end

    private

    def cancel_package
      result = CancelPaidPackage.call(
        ticket: @ticket,
        actor: @manager,
        idempotency_key: "cancel-package-#{SecureRandom.hex(8)}"
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end

    def create_payment_for(item)
      order = item.order
      Orders::Payment.create!(
        order:,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "succeeded",
        amount_minor: order.total_minor,
        currency: order.charge_currency,
        commercial_signature: order.commercial_signature,
        buyer_fee_minor: 0,
        organizer_fee_minor: 0,
        idempotency_key: "payment-#{SecureRandom.hex(6)}",
        provider_reference: "provider-#{SecureRandom.hex(4)}",
        accepted_at: Time.current,
        succeeded_at: Time.current,
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: order.expires_at + 5.minutes
      )
    end

    def consume_package
      access = @product.product_accesses.first
      date = access.event_date
      date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
      device = Ticketing::ScannerDevice.create!(
        organization: @event.organization,
        device_identifier: "cancel-package-scanner-#{SecureRandom.hex(4)}",
        token_digest: Ticketing::ScannerDevice.token_digest_for(token: SecureRandom.hex(32))
      )
      assignment = Ticketing::ScannerDeviceAssignment.create!(
        scanner_device: device, event: @event, assigned_by: @manager
      )
      claims = Ticketing::Qr::Verifier.call(
        token: @ticket.current_credential_generation.credentials.first.qr_token
      ).value

      result = Ticketing::Admissions::Consume.call(
        claims:,
        product_access: access,
        assignment:,
        client_scan_id: SecureRandom.uuid,
        scanned_at: date.starts_at + 1.minute,
        lookup_via: "qr",
        identity_check: nil,
        now: date.starts_at + 1.minute
      )
      assert_predicate result, :success?, result.error&.message
    end
  end
end
