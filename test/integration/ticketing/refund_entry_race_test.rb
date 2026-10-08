# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RefundEntryRaceTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      @payment = create_payment_for(@ticket.order_item)
    end

    test "a package cannot be both successfully admitted and cancelled" do
      result = CancelPaidPackage.call(
        ticket: @ticket,
        actor: @manager,
        idempotency_key: "race-cancel-#{SecureRandom.hex(8)}"
      )

      assert_predicate result, :success?, result.error&.message
      refund = result.value
      assert_equal "active", @ticket.reload.status
      assert @ticket.package_suspended?

      access = @product.product_accesses.first
      access.event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
      claims = Ticketing::Qr::Verifier.call(
        token: @ticket.current_credential_generation.credentials.first.qr_token
      ).value
      assignment = build_scanner_assignment(
        event: @event,
        assigned_by: @manager,
        device_identifier: "refund-race-scanner-#{SecureRandom.hex(4)}"
      )

      admission = Ticketing::Admissions::Consume.call(
        claims:,
        product_access: access,
        assignment:,
        client_scan_id: SecureRandom.uuid,
        scanned_at: Time.current,
        lookup_via: "qr",
        identity_check: nil,
        now: Time.current
      )

      assert_predicate admission, :success?, admission.error&.message
      assert_equal "revoked", admission.value.result
      assert_equal "created", refund.reload.status
      assert_empty Ticketing::AdmissionUse.where(admission_slot_id: @ticket.admission_slots.select(:id))
    end

    private

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
  end
end
