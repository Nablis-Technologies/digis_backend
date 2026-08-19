# frozen_string_literal: true

require "test_helper"

module Reconciliation
  class DomainJobsTest < ActiveJob::TestCase
    include Finance::PayoutTestHelpers
    include Marketplace::SellerPayoutTestHelpers

    setup do
      @now = Time.utc(2026, 8, 19, 12, 0, 0)
    end

    test "outbox reconciliation dispatches only one bounded overdue batch" do
      first = core_outbox_events(:exhausted)
      first.update!(available_at: @now - 3.hours)
      second = create_outbox_event(available_at: @now - 1.hour, attempts: 10)
      Core::OutboxEvent.where(published_at: nil).where.not(id: [ first.id, second.id ])
        .update_all(available_at: @now)
      dispatched = Core::BaseService::Result.success(first)

      Core::Outbox::Dispatch.expects(:call).with(event_id: first.id).returns(dispatched)

      Reconciliation::OutboxJob.perform_now(1, now: @now)

      assert_equal 10, second.reload.attempts
    end

    test "payment reconciliation delegates only one due attempt and records its transition" do
      first = create_payment(user: core_users(:attendee), suffix: "first")
      second = create_payment(user: core_users(:support), suffix: "second")
      result = Core::BaseService::Result.success(first)
      test_case = self
      expected_now = @now

      original_call = Orders::ExpireSettlementGrace.method(:call)
      Orders::ExpireSettlementGrace.define_singleton_method(:call) do |payment_id:, now:|
        test_case.assert_equal first.id, payment_id
        test_case.assert_equal expected_now, now
        first.update_columns(status: "unknown")
        result
      end
      begin
        Reconciliation::PaymentAttemptsJob.perform_now(1, now: @now)
      ensure
        Orders::ExpireSettlementGrace.define_singleton_method(:call, original_call)
      end

      audit = Core::AuditLog.find_by!(auditable_type: first.class.name, auditable_id: first.id)
      assert_equal "reconciliation.payment_attempt.state_changed", audit.action
      assert_equal "unknown", first.reload.status
      assert_equal "processing", second.reload.status
    end

    test "refund reconciliation delegates due processing obligations in a bounded batch" do
      first = create_refund(suffix: "first")
      second = create_refund(suffix: "second")
      first.update!(next_retry_at: @now - 2.hours)
      second.update!(next_retry_at: @now - 1.hour)

      Orders::ReconcileRefund.expects(:call).with(refund: first, now: @now).returns(
        Core::BaseService::Result.success(first)
      )

      Reconciliation::RefundsJob.perform_now(1, now: @now)

      assert_equal "processing", second.reload.status
    end

    test "organizer payout reconciliation delegates a bounded processing batch" do
      setup_payout_context
      first = create_processing_payout("first")
      second = create_processing_payout("second")
      adapter = Object.new

      Finance::PayoutProviders::Registry.expects(:fetch).with("chapa").returns(adapter)
      Finance::ReconcilePayout.expects(:call).with(payout: first, adapter:, at: @now).returns(
        Core::BaseService::Result.success(first)
      )

      Reconciliation::OrganizerPayoutsJob.perform_now(1, now: @now)

      assert_equal "processing", second.reload.status
    end

    test "seller payout reconciliation delegates a bounded processing batch" do
      setup_seller_payout_context
      first = create_processing_seller_payout("first")
      second = create_processing_seller_payout("second")
      adapter = Object.new

      Marketplace::PayoutProviders::Registry.expects(:fetch).with("telebirr").returns(adapter)
      Marketplace::ReconcileSellerPayout.expects(:call).with(payout: first, adapter:, at: @now).returns(
        Core::BaseService::Result.success(first)
      )

      Reconciliation::SellerPayoutsJob.perform_now(1, now: @now)

      assert_equal "processing", second.reload.status
    end

    test "credential reconciliation tombstones a revoked projection without changing admission history" do
      ticket, credential = create_ticket_with_revoked_credential
      admission_use = Ticketing::AdmissionUse.create!(
        admission_slot: ticket.admission_slots.first,
        product_access: ticket.event_product.product_accesses.first,
        credential:,
        checkin_log: create_checkin_log(ticket),
        usage_number: 1,
        used_at: @now
      )
      credential.attendee_index_entry.update!(removed: false)

      Reconciliation::CredentialProjectionJob.perform_now(1, now: @now)

      assert_predicate credential.reload, :persisted?
      assert_predicate credential.attendee_index_entry.reload, :removed?
      assert Ticketing::AdmissionUse.exists?(admission_use.id)
      assert_equal "revoked", credential.status
    end

    private

    def create_outbox_event(available_at:, attempts:)
      Core::OutboxEvent.create!(
        topic: "orders",
        event_type: "orders.payment_event.received",
        aggregate_type: "Orders::Payment",
        aggregate_id: SecureRandom.uuid,
        payload: { payment_event_id: SecureRandom.uuid },
        idempotency_key: "reconciliation-outbox-#{SecureRandom.uuid}",
        occurred_at: available_at,
        available_at:,
        attempts:
      )
    end

    def create_payment(user:, suffix:)
      order = Orders::Order.create!(
        event: events_events(:ready_listing),
        buyer_user: user,
        sales_channel: "online",
        status: "pending_payment",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 1_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 1_000,
        settlement_currency: "ETB",
        settlement_total_minor: 1_000,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: @now + 1.hour,
        expires_at: @now - 1.hour,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      Orders::Payment.create!(
        order:,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "processing",
        amount_minor: 1_000,
        currency: "ETB",
        commercial_signature: order.commercial_signature,
        buyer_fee_minor: 0,
        organizer_fee_minor: 0,
        idempotency_key: "reconciliation-payment-#{suffix}-#{SecureRandom.hex(4)}",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @now - 1.hour
      )
    end

    def create_refund(suffix:)
      payment = create_payment(user: core_users(:attendee), suffix: "refund-#{suffix}")
      payment.update!(status: "succeeded")
      payment.order.update!(status: "fulfilled", paid_at: @now)
      Orders::Refund.create!(
        payment:,
        type: "payment_reversal",
        idempotency_key: "reconciliation-refund-#{suffix}-#{SecureRandom.hex(4)}",
        amount_minor: payment.amount_minor,
        currency: payment.currency,
        status: "processing",
        pending_reason: "provider_processing",
        next_retry_at: @now - 1.hour,
        reason_code: "late_payment"
      )
    end

    def create_processing_payout(suffix)
      Finance::Payout.create!(
        organization: @organization,
        currency: "ETB",
        status: "processing",
        amount_minor: 1_000,
        provider: "chapa",
        idempotency_key: "reconciliation-payout-#{suffix}-#{SecureRandom.hex(4)}",
        requested_at: @now
      )
    end

    def create_processing_seller_payout(suffix)
      Marketplace::SellerPayout.create!(
        seller_user: @seller,
        seller_payout_account: @account,
        provider: "telebirr",
        amount_minor: 1_000,
        currency: "ETB",
        status: "processing",
        idempotency_key: "reconciliation-seller-payout-#{suffix}-#{SecureRandom.hex(4)}",
        requested_at: @now
      )
    end

    def create_ticket_with_revoked_credential
      ticket = Ticketing::Packages::Issue.call(
        registration: create_registration,
        unit_number: 1
      ).value
      credential = ticket.current_credential_generation.credentials.sole
      credential.update!(status: "revoked", revoked_at: @now, revocation_reason: "test")
      Ticketing::CredentialRevocation.create!(
        event: ticket.event,
        credential:,
        reason: "test",
        revoked_at: @now,
        revocation_version: 1
      )
      [ ticket, credential ]
    end

    def create_registration
      product = Catalog::Products::CreateDraft.call(
        event: events_events(:ready_listing),
        actor: core_users(:super_admin),
        product_attributes: { name: "Reconciliation ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      event_date = events_events(:ready_listing).event_dates.create!(
        starts_at: 2.days.from_now, ends_at: 2.days.from_now + 4.hours, status: "scheduled"
      )
      product.product_accesses.create!(event_date:, type: "venue", usage_limit: 1)
      Ticketing::Registration.create!(
        event: events_events(:ready_listing), ticket_type: product.ticket_type, user: core_users(:attendee),
        created_by: core_users(:attendee), source: "self_service", identity_digest: SecureRandom.hex(32),
        package_quantity: 1, admissions_per_unit_snapshot: 1, party_size: 1, status: "confirmed",
        submitted_at: @now, confirmed_at: @now
      )
    end

    def create_checkin_log(ticket)
      Ticketing::CheckinLog.create!(
        ticket:,
        credential: ticket.current_credential_generation.credentials.sole,
        credential_version: ticket.credential_version,
        product_access: ticket.event_product.product_accesses.first,
        event_date: ticket.event_product.product_accesses.first.event_date,
        client_scan_id: SecureRandom.uuid,
        result: "success",
        lookup_via: "qr",
        identity_check_result: "not_required",
        scanned_at: @now,
        received_at: @now
      )
    end
  end
end
