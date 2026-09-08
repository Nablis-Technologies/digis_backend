# frozen_string_literal: true

require "test_helper"

module Ticketing
  class GuestTicketViewTokenTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
    end

    test "issues and verifies a token bound to the current credential generation" do
      token = GuestTicketViewToken.issue(ticket: @ticket)

      result = GuestTicketViewToken.verify(token)

      assert_predicate result, :success?
      assert_equal @ticket.id, result.value.ticket_id
      assert_equal @ticket.credential_version, result.value.credential_version
      assert_operator result.value.expires_at, :>, Time.current
    end

    test "rejects a tampered token" do
      token = GuestTicketViewToken.issue(ticket: @ticket)

      result = GuestTicketViewToken.verify("#{token}tampered")

      assert_predicate result, :failure?
      assert_equal "invalid_guest_ticket_view", result.error.code
    end

    test "rejects a token whose retention window has expired" do
      @product.product_accesses.first.event_date.update_columns(
        starts_at: 32.days.ago,
        ends_at: 31.days.ago
      )

      result = GuestTicketViewToken.verify(GuestTicketViewToken.issue(ticket: @ticket))

      assert_predicate result, :failure?
      assert_equal "invalid_guest_ticket_view", result.error.code
    end
  end
end
