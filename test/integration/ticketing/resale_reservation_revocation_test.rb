# frozen_string_literal: true

require "test_helper"

module Ticketing
  class ResaleReservationRevocationTest < ActiveSupport::TestCase
    include Marketplace::ResaleReservationTestHelpers

    setup do
      setup_resale_reservation_context
      @seller_credential = @ticket.current_credential_generation.credentials.first
      @seller_index = @seller_credential.attendee_index_entry
    end

    test "tombstones the seller credential before exposing the reserved order" do
      result = Marketplace::ReserveListing.call(
        listing: @listing,
        buyer: @buyer,
        idempotency_key: "reservation-revocation-#{SecureRandom.hex(8)}"
      )

      assert_predicate result, :success?, result.error&.message
      order = result.value

      assert_equal "revoked", @seller_credential.reload.status
      assert_predicate @seller_credential.credential_revocation, :present?
      assert @seller_index.reload.removed
      assert @ticket.reload.package_suspended?
      assert_equal order.id, @listing.reload.reserved_order_id
      publication = Core::OutboxEvent.find_by!(
        event_type: "marketplace.resale_listing.reserved",
        aggregate_id: @listing.id
      )
      assert_equal @ticket.id, publication.payload.fetch("ticket_id")
      assert_equal @ticket.reload.revocation.revocation_version, publication.payload.fetch("revocation_version")
      assert_equal @event.reload.attendee_index_version, publication.payload.fetch("attendee_index_version")
    end
  end
end
