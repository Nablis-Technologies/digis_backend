# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ExpireReservationTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include ResaleReservationTestHelpers

    setup do
      setup_resale_reservation_context
    end

    test "expires a failed reservation and restores seller access through a new generation" do
      reserve_resale_listing
      result = ExpireReservation.call(listing: @listing, at: @expiry_at)

      assert_predicate result, :success?, result.error&.message
      assert_equal "expired", @listing.reload.status
      assert_nil @listing.reserved_order_id
      assert_equal "expired", @order.reload.status
      assert_equal "checkout_expired", @order.closed_reason
      assert_equal "released", @buyer_allocation.reload.status
      assert_equal "checkout_expired", @buyer_allocation.release_reason

      ticket = @ticket.reload
      generation = ticket.current_credential_generation.reload
      assert_equal @seller_generation.version + 1, generation.version
      assert_equal "group", generation.mode
      assert_equal "active", generation.status
      assert_equal "revoked", @seller_generation.reload.status
      assert_equal "active", generation.credentials.sole.status
      refute_predicate ticket, :package_suspended?
      assert_equal @owner.id, ticket.owner_user_id

      assert_equal 1, Core::AuditLog.where(
        action: "marketplace.resale_listing.seller_access_restored",
        auditable_id: @listing.id
      ).count
      assert_equal 1, Core::OutboxEvent.where(
        event_type: "marketplace.resale_listing.seller_access_restored",
        aggregate_id: @listing.id
      ).count
      assert_equal 1, Core::OutboxEvent.where(
        event_type: "marketplace.resale_listing.expired",
        aggregate_id: @listing.id
      ).count

      replacement_listing = ActivateListing.call(
        ticket: @ticket,
        actor: @owner,
        asking_amount_minor: 2_500,
        idempotency_key: "reactivate-after-expiry-#{SecureRandom.hex(8)}"
      )
      assert_predicate replacement_listing, :success?, replacement_listing.error&.message
      refute_equal @listing.id, replacement_listing.value.id
    end

    test "replays expiry without creating another seller generation" do
      reserve_resale_listing
      first = ExpireReservation.call(listing: @listing, at: @expiry_at)
      generation_count = Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).count

      second = ExpireReservation.call(listing: @listing, at: @expiry_at + 1.second)

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :success?, second.error&.message
      assert_equal generation_count, Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).count
      assert_equal 1, Core::AuditLog.where(
        action: "marketplace.resale_listing.seller_access_restored",
        auditable_id: @listing.id
      ).count
    end

    test "expires the listing when resale is disabled while the hold is open" do
      reserve_resale_listing
      @ticket_type.update!(
        resale_enabled: false,
        resale_price_cap_type: nil,
        resale_fixed_cap_minor: nil,
        resale_fixed_cap_currency: nil,
        resale_percentage_cap_bps: nil
      )

      result = ExpireReservation.call(listing: @listing, at: @expiry_at)

      assert_predicate result, :success?, result.error&.message
      assert_equal "expired", @listing.reload.status
      assert_nil @listing.reserved_order_id
      assert_equal "active", @ticket.reload.current_credential_generation.status
      refute_predicate @ticket.reload, :package_suspended?
    end

    test "expires the listing after its snapshotted resale cutoff" do
      reserve_resale_listing
      @listing.update_columns(resale_cutoff_at: @expiry_at - 1.second)
      @ticket_type.update_columns(transfer_cutoff_seconds_before_start: 365.days.to_i)

      result = ExpireReservation.call(listing: @listing, at: @expiry_at)

      assert_predicate result, :success?, result.error&.message
      assert_equal "expired", @listing.reload.status
      assert_equal "active", @ticket.reload.current_credential_generation.status
    end

    test "expires the listing when the current resale policy limit is reached" do
      @ticket.update_columns(completed_resale_count: 1)
      @listing.update_columns(resale_count_before: 1)
      @ticket_type.update_columns(max_completed_resales: 1)
      reserve_resale_listing

      result = ExpireReservation.call(listing: @listing, at: @expiry_at)

      assert_predicate result, :success?, result.error&.message
      assert_equal "expired", @listing.reload.status
      assert_equal "active", @ticket.reload.current_credential_generation.status
    end

    test "cancelling a reserved listing releases checkout and restores seller access" do
      reserve_resale_listing
      result = CancelListing.call(
        listing: @listing,
        idempotency_key: "cancel-reserved-#{SecureRandom.hex(8)}",
        reason: "seller_requested"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "cancelled", @listing.reload.status
      assert_equal "expired", @order.reload.status
      assert_equal "released", @buyer_allocation.reload.status
      assert_equal "active", @ticket.reload.current_credential_generation.status
      refute_predicate @ticket.reload, :package_suspended?
    end

    test "reserves schedule one expiry job for the listing deadline" do
      assert_enqueued_with(job: Marketplace::ExpireReservationJob, args: [ @listing.id ]) do
        result = ReserveListing.call(
          listing: @listing,
          buyer: @buyer,
          idempotency_key: "schedule-expiry-#{SecureRandom.hex(8)}"
        )
        assert_predicate result, :success?, result.error&.message
      end
    end

    private

    def reserve_resale_listing
      reservation = ReserveListing.call(
        listing: @listing,
        buyer: @buyer,
        idempotency_key: "expire-reservation-#{SecureRandom.hex(8)}"
      )
      assert_predicate reservation, :success?, reservation.error&.message
      @order = reservation.value
      @order_item = @order.order_items.find_by!(resale_listing_id: @listing.id)
      @buyer_allocation = Ticketing::PurchaseLimitAllocation.find_by!(
        registration_id: @order_item.registration_id
      )
      @seller_generation = @ticket.reload.current_credential_generation
      @expiry_at = @listing.reload.reservation_expires_at
    end
  end
end
