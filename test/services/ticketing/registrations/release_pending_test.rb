# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Registrations
    class ReleasePendingTest < ActiveSupport::TestCase
      include Ticketing::ConsentTestHelpers

      setup do
        setup_consent_context
      end

      test "cancels a buyer-owned pending registration and audits replay once" do
        subject = -> do
          ReleasePending.call(
            registration: @registration,
            buyer: @actor,
            idempotency_key: "release-pending-registration"
          )
        end

        assert_audit_idempotent(
          subject,
          action: "ticketing.registration.pending_released",
          auditable_type: "Ticketing::Registration",
          auditable_id: @registration.id
        )
        assert_equal "cancelled", @registration.reload.status
        assert_not_nil @registration.cancelled_at
      end

      test "rejects release by another buyer" do
        result = ReleasePending.call(
          registration: @registration,
          buyer: core_users(:support),
          idempotency_key: "release-pending-forbidden"
        )

        assert_predicate result, :failure?
        assert_equal "registration_not_owned", result.error.code
        assert_equal "pending_payment", @registration.reload.status
      end
    end
  end
end
