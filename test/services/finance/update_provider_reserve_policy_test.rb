# frozen_string_literal: true

require "test_helper"

module Finance
  class UpdateProviderReservePolicyTest < ActiveSupport::TestCase
    test "updates a reserve target with audited idempotency" do
      actor = core_users(:super_admin)

      result = Finance::UpdateProviderReservePolicy.call(
        provider: "chapa",
        currency: "ETB",
        target_minor: 25_000,
        actor:,
        idempotency_key: "reserve-policy-1"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal 25_000, result.value.reload.target_minor
      assert_equal 1, Core::AuditLog.where(action: "finance.reserve_policy.updated").count

      replay = Finance::UpdateProviderReservePolicy.call(
        provider: "chapa",
        currency: "ETB",
        target_minor: 25_000,
        actor:,
        idempotency_key: "reserve-policy-1"
      )

      assert_predicate replay, :success?, replay.error&.message
      assert_equal result.value.id, replay.value.id
      assert_equal 1, Core::AuditLog.where(action: "finance.reserve_policy.updated").count
    end

    test "rejects unauthorized or conflicting idempotent updates" do
      unauthorized = Finance::UpdateProviderReservePolicy.call(
        provider: "chapa",
        currency: "ETB",
        target_minor: 1_000,
        actor: core_users(:attendee),
        idempotency_key: "reserve-policy-unauthorized"
      )

      assert_predicate unauthorized, :failure?
      assert_equal "unauthorized", unauthorized.error.code

      Finance::UpdateProviderReservePolicy.call(
        provider: "chapa",
        currency: "ETB",
        target_minor: 1_000,
        actor: core_users(:super_admin),
        idempotency_key: "reserve-policy-conflict"
      )
      conflict = Finance::UpdateProviderReservePolicy.call(
        provider: "chapa",
        currency: "ETB",
        target_minor: 2_000,
        actor: core_users(:super_admin),
        idempotency_key: "reserve-policy-conflict"
      )

      assert_predicate conflict, :failure?
      assert_equal "idempotency_conflict", conflict.error.code
      assert_equal 1_000, Finance::ProviderReservePolicy.find_by!(provider: "chapa", currency: "ETB").target_minor
    end
  end
end
