# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Suspensions
    class ResolveTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow
      end

      test "revokes a free package terminally and invalidates its current generation" do
        registration = create_confirmed_registration
        free_ticket = Ticketing::Packages::Issue.call(registration:, unit_number: 1).value
        opened = open_suspension(free_ticket)

        result = Resolve.call(
          suspension: opened,
          actor: @manager,
          resolution: "revoked_free",
          resolution_reason: "organizer_cancellation",
          idempotency_key: "suspension-resolve-#{SecureRandom.hex(8)}"
        )

        assert_predicate result, :success?, result.error&.message
        suspension = result.value
        free_ticket.reload

        assert_equal "revoked_free", suspension.status
        assert_equal "void", free_ticket.status
        assert free_ticket.revocation.is_dead
        assert_not free_ticket.revocation.is_suspended
        assert_equal "revoked", free_ticket.current_credential_generation.reload.status
        assert free_ticket.credentials.reload.all? { |credential| credential.status == "revoked" }
      end

      test "does not directly invalidate a paid package before refund success" do
        opened = open_suspension(@ticket)

        result = Resolve.call(
          suspension: opened,
          actor: @manager,
          resolution: "revoked_free",
          resolution_reason: "organizer_cancellation",
          idempotency_key: "suspension-resolve-#{SecureRandom.hex(8)}"
        )

        assert_predicate result, :failure?
        assert_equal "paid_refund_required", result.error.code
        assert_equal "active", opened.reload.status
        assert_equal "active", @ticket.reload.status
        assert_not @ticket.revocation.is_dead
        assert @ticket.revocation.is_suspended
      end

      private

      def open_suspension(ticket)
        Ticketing::Suspensions::Open.call(
          ticket:,
          actor: @manager,
          reason_code: "suspected_fraud",
          review_deadline_at: 3.days.from_now,
          idempotency_key: "suspension-open-#{SecureRandom.hex(8)}"
        ).value
      end
    end
  end
end
