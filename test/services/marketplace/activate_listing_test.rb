# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ActivateListingTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers
    include CommercialResaleTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 3)
      setup_commercial_terms
      configure_resale_policy
    end

    test "activates an eligible whole package and snapshots the resale boundary" do
      travel_to(Time.current.change(usec: 0)) do
        result = ActivateListing.call(
          ticket: @ticket,
          actor: @owner,
          asking_amount_minor: 2_500,
          idempotency_key: "activate-listing-#{SecureRandom.hex(8)}"
        )

        assert_predicate result, :success?, result.error&.message
        listing = result.value
        assert_equal "active", listing.status
        assert_equal @event.id, listing.event_id
        assert_equal @ticket.id, listing.ticket_id
        assert_equal @product.ticket_type.id, listing.ticket_type_id
        assert_equal @owner.id, listing.seller_user_id
        assert_equal 2_500, listing.asking_amount_minor
        assert_equal "ETB", listing.currency
        assert_equal 3_000, listing.seller_acquisition_product_value_minor
        assert_equal "fixed", listing.cap_type_snapshot
        assert_equal 3_000, listing.fixed_cap_minor_snapshot
        assert_nil listing.percentage_cap_bps_snapshot
        assert_equal 3_000, listing.calculated_cap_minor
        assert_equal 0, listing.resale_count_before
        assert_equal 2, listing.max_completed_resales_snapshot
        assert_equal @product.product_accesses.first.event_date.starts_at - 1.hour, listing.resale_cutoff_at
        assert_equal @resale_component.id, listing.commercial_fee_component_id
        assert_equal @commercial_version.id, listing.commercial_fee_schedule_version_id
        assert_predicate listing.activated_at, :present?
        assert_equal @ticket.current_credential_generation_id, @ticket.reload.current_credential_generation_id
        assert_equal 1, ResaleListing.where(ticket_id: @ticket.id).count
      end
    end

    test "replays the same activation key without creating a second listing" do
      key = "activate-listing-replay-#{SecureRandom.hex(8)}"
      first = ActivateListing.call(ticket: @ticket, actor: @owner, asking_amount_minor: 2_500, idempotency_key: key)
      second = ActivateListing.call(ticket: @ticket, actor: @owner, asking_amount_minor: 2_500, idempotency_key: key)

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :success?, second.error&.message
      assert_equal first.value.id, second.value.id
      assert_equal 1, ResaleListing.where(ticket_id: @ticket.id).count
    end

    test "rejects a changed request that reuses an activation key" do
      key = "activate-listing-conflict-#{SecureRandom.hex(8)}"
      first = ActivateListing.call(ticket: @ticket, actor: @owner, asking_amount_minor: 2_500, idempotency_key: key)
      second = ActivateListing.call(ticket: @ticket, actor: @owner, asking_amount_minor: 2_000, idempotency_key: key)

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :failure?
      assert_equal "idempotency_conflict", second.error.code
    end

    test "rejects a free acquisition" do
      @ticket.update!(
        current_acquisition_type: "free_registration",
        current_acquisition_order_item: nil,
        current_acquisition_product_value_minor: 0
      )

      assert_activation_failure("paid_acquisition_required")
    end

    test "rejects a delegated package" do
      result = activate_delegated_ticket
      assert_predicate result, :success?, result.error&.message

      assert_activation_failure("group_mode_required")
    end

    test "rejects a package after one admission slot has been used" do
      create_admission_use

      assert_activation_failure("package_already_used")
    end

    test "rejects a package with an active stream access because stream use is not persisted yet" do
      @product.product_accesses.create!(
        event_date: @product.product_accesses.first.event_date,
        type: "stream",
        required_access_protection: "signed",
        usage_limit: 1
      )

      assert_activation_failure("stream_usage_unavailable")
    end

    test "rejects a package with a pending transfer" do
      token = SecureRandom.hex(16)
      Ticketing::TicketTransfer.create!(
        ticket: @ticket,
        from_user: @owner,
        to_user: @recipient,
        initiated_by: @owner,
        token:,
        token_digest: Ticketing::TicketTransfer.token_digest_for(token:),
        status: "pending",
        previous_version: @ticket.credential_version,
        expires_at: 1.hour.from_now
      )

      assert_activation_failure("pending_transfer")
    end

    test "rejects a completed resale count at the policy ceiling" do
      @ticket.update!(completed_resale_count: @ticket_type.max_completed_resales)

      assert_activation_failure("resale_count_exhausted")
    end

    test "rejects a fixed cap in a different currency" do
      @ticket.update_column(:current_acquisition_currency, "USD")

      assert_activation_failure("currency_mismatch")
    end

    test "rejects an asking amount above the calculated cap" do
      assert_activation_failure("asking_amount_exceeds_cap", amount: 3_001)
    end

    test "rejects a disabled resale policy" do
      result = ConfigureTicketTypeResale.call(
        ticket_type: @ticket_type,
        actor: @owner,
        attributes: { resale_enabled: false },
        idempotency_key: "activate-test-disable-policy"
      )
      assert_predicate result, :success?, result.error&.message

      assert_activation_failure("resale_disabled")
    end

    test "cancels an unsold listing idempotently" do
      listing = activate_listing
      key = "cancel-listing-#{SecureRandom.hex(8)}"

      first = CancelListing.call(listing:, idempotency_key: key, reason: "resale_policy_disabled")
      second = CancelListing.call(listing:, idempotency_key: key, reason: "resale_policy_disabled")

      assert_predicate first, :success?, "#{first.error&.message} #{first.error&.errors.inspect}"
      assert_predicate second, :success?, "#{second.error&.message} #{second.error&.errors.inspect}"
      assert_equal listing.id, first.value.id
      assert_equal listing.id, second.value.id
      assert_equal "cancelled", listing.reload.status
      assert_predicate listing.closed_at, :present?
    end

    test "disabling resale cancels active listings" do
      listing = activate_listing

      result = ConfigureTicketTypeResale.call(
        ticket_type: @ticket_type,
        actor: @owner,
        attributes: { resale_enabled: false },
        idempotency_key: "activate-test-cancel-listing"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "cancelled", listing.reload.status
      assert_predicate listing.closed_at, :present?
    end

    private

    def activate_listing(amount: 2_500, key: "activate-listing-helper-#{SecureRandom.hex(8)}")
      result = ActivateListing.call(
        ticket: @ticket,
        actor: @owner,
        asking_amount_minor: amount,
        idempotency_key: key
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end

    def assert_activation_failure(code, amount: 2_500)
      result = ActivateListing.call(
        ticket: @ticket,
        actor: @owner,
        asking_amount_minor: amount,
        idempotency_key: "activate-listing-failure-#{SecureRandom.hex(8)}"
      )

      assert_predicate result, :failure?
      assert_equal code, result.error.code
    end

    def configure_resale_policy
      @ticket_type = @product.ticket_type
      @ticket_type.update!(
        resale_enabled: true,
        resale_cutoff_seconds_before_start: 3_600,
        resale_price_cap_type: "fixed",
        resale_fixed_cap_minor: 3_000,
        resale_fixed_cap_currency: "ETB",
        max_completed_resales: 2
      )
    end

    def setup_commercial_terms
      @organization = @event.organization
      @quoted_at = Time.current.change(usec: 0)
      @commercial_version = create_active_commercial_version(
        code: "resale_listing_#{SecureRandom.hex(6)}",
        schedule_type: "platform_default"
      ) do |version|
        create_fixed_component(version, component_type: "buyer_service_fee", fixed_amount_minor: 100)
        create_fixed_component(version, component_type: "processing_cost_recovery", fixed_amount_minor: 50)
        @resale_component = create_fixed_component(
          version,
          component_type: "resale_platform_fee",
          fixed_amount_minor: 300,
          sale_context: "resale",
          sales_channel: "resale",
          charged_to: "organizer",
          funded_by: "organizer"
        )
      end
    end

    def create_admission_use
      access = @product.product_accesses.first
      credential = @ticket.current_credential_generation.credentials.first
      checkin = Ticketing::CheckinLog.create!(
        ticket: @ticket,
        credential:,
        credential_version: @ticket.credential_version,
        product_access: access,
        event_date: access.event_date,
        client_scan_id: SecureRandom.uuid,
        result: "success",
        lookup_via: "qr",
        identity_check_result: "not_required",
        scanned_at: Time.current,
        received_at: Time.current
      )
      Ticketing::AdmissionUse.create!(
        admission_slot: @ticket.admission_slots.first,
        product_access: access,
        credential:,
        checkin_log: checkin,
        usage_number: 1,
        used_at: Time.current
      )
    end
  end
end
