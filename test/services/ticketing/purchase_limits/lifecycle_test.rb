# frozen_string_literal: true

require "test_helper"

module Ticketing
  module PurchaseLimits
    class LifecycleTest < ActiveSupport::TestCase
      include Ticketing::ConsentTestHelpers

      setup do
        setup_consent_context
        @ticket_type.update!(max_packages_per_user: 2)
      end

      test "commits reserved allocations and is idempotent" do
        Reserve.call(
          registration: @registration,
          user: @actor,
          quantity: 2,
          expires_at: 10.minutes.from_now,
          idempotency_key: "lifecycle-reserve"
        )

        subject = lambda do
          Commit.call(
            registration: @registration,
            user: @actor,
            idempotency_key: "lifecycle-commit"
          )
        end

        assert_idempotent(subject, counter: -> { PurchaseLimitAllocation.where(status: "committed").count })
        assert_equal 2, PurchaseLimitAllocation.where(registration: @registration, status: "committed").count
      end

      test "releases reserved allocations with a controlled reason" do
        Reserve.call(
          registration: @registration,
          user: @actor,
          quantity: 1,
          expires_at: 10.minutes.from_now,
          idempotency_key: "release-reserve"
        )

        result = Release.call(
          registration: @registration,
          user: @actor,
          reason: "checkout_expired",
          idempotency_key: "release-reservation"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal [ "released" ], result.value.map(&:status).uniq
        assert_equal [ "checkout_expired" ], result.value.map(&:release_reason).uniq
      end

      test "availability includes a registration-specific override" do
        result = GrantOverride.call(
          registration: @registration,
          approved_by: core_users(:super_admin),
          additional_packages: 3,
          reason_code: "accessibility",
          idempotency_key: "grant-limit-override"
        )

        assert_predicate result, :success?, result.error&.message
        availability = Availability.call(
          ticket_type: @ticket_type,
          user: @actor,
          registration: @registration
        )

        assert_predicate availability, :success?, availability.error&.message
        assert_equal 5, availability.value.limit
        assert_equal 5, availability.value.available
      end

      test "override is immutable and audited" do
        result = GrantOverride.call(
          registration: @registration,
          approved_by: core_users(:super_admin),
          additional_packages: 1,
          reason_code: "service_recovery",
          idempotency_key: "audited-limit-override"
        )

        assert_predicate result, :success?, result.error&.message
        audit = Core::AuditLog.find_by!(audit_key: "ticketing-purchase-limit-override-#{result.value.idempotency_key}")
        assert_equal "ticketing.purchase_limit_override.granted", audit.action
        assert_raises(ActiveRecord::RecordInvalid) do
          result.value.update!(additional_packages: 2)
        end
        assert_not result.value.destroy
        assert result.value.errors[:base].any?
      end

      test "rejects a non-manager override" do
        result = GrantOverride.call(
          registration: @registration,
          approved_by: @actor,
          additional_packages: 1,
          reason_code: "accessibility",
          idempotency_key: "unauthorized-limit-override"
        )

        assert_predicate result, :failure?
        assert_equal "purchase_limit_override_forbidden", result.error.code
      end
    end
  end
end
