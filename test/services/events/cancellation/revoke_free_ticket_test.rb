# frozen_string_literal: true

require "test_helper"

module Events
  module Cancellation
    class RevokeFreeTicketTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        @event = events_events(:ready_listing)
        @owner = core_users(:attendee)
        @manager = core_users(:super_admin)
        @product = create_package_product(admissions_per_unit: 1, delegation_enabled: false, transferable: false)
        @registration = create_confirmed_registration
        @ticket = Ticketing::Packages::Issue.call(registration: @registration, unit_number: 1).value
      end

      test "voids a free ticket and publishes credential tombstones without a refund" do
        result = RevokeFreeTicket.call(ticket: @ticket)

        assert_predicate result, :success?, result.error&.message
        assert_equal "void", @ticket.reload.status
        assert_equal "revoked", @ticket.current_credential_generation.reload.status
        assert @ticket.credentials.reload.all? { |credential| credential.status == "revoked" }
        assert @ticket.revocation.reload.is_dead
        assert_empty Orders::Refund.where(payment_id: @ticket.order_item&.order_id)
      end
    end
  end
end
