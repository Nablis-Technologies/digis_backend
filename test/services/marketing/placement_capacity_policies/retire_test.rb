# frozen_string_literal: true

require "test_helper"

module Marketing
  module PlacementCapacityPolicies
    class RetireTest < ActiveSupport::TestCase
      setup do
        @actor = core_users(:super_admin)
      end

      test "retirement stops future capacity resolution and records operator evidence" do
        start_at = 1.day.ago
        policy = activate(create_policy(effective_from: start_at, effective_until: 2.days.from_now))
        assert_equal policy.id, PlacementCapacityPolicy.active_for(surface: policy.surface, at: Time.current).id

        result = retire(policy, idempotency_key: "capacity-retire-#{policy.id}")

        assert_predicate result, :success?, result.error&.message
        assert_equal "retired", result.value.status
        assert_equal @actor.id, result.value.retired_by_id
        assert_not_nil result.value.retired_at
        assert_nil PlacementCapacityPolicy.active_for(surface: policy.surface, at: Time.current)
        audit = Core::AuditLog.find_by!(
          action: "marketing.placement_capacity_policy.retired", auditable_id: policy.id
        )
        assert_equal "Retired preview capacity", audit.metadata.fetch("reason")
      end

      test "same-key retirement replay is idempotent and a new key cannot retire twice" do
        policy = activate(create_policy(effective_from: 1.day.ago, effective_until: 2.days.from_now))
        operation = -> { retire(policy, idempotency_key: "capacity-retire-replay-#{policy.id}") }
        assert_audit_idempotent(
          operation, action: "marketing.placement_capacity_policy.retired",
          auditable_type: "Marketing::PlacementCapacityPolicy", auditable_id: policy.id
        )

        assert_predicate operation.call, :success?
        conflict = retire(policy, idempotency_key: "capacity-retire-again-#{policy.id}")

        assert_predicate conflict, :failure?
        assert_equal "capacity_policy_not_retirable", conflict.error.code
      end

      test "rejects a changed retirement reason under the same idempotency key" do
        policy = activate(create_policy(effective_from: 1.day.ago, effective_until: 2.days.from_now))
        key = "capacity-retire-conflict-#{policy.id}"
        first = retire(policy, idempotency_key: key, reason: "Original reason")
        replay = retire(policy, idempotency_key: key, reason: "Changed reason")

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :failure?
        assert_equal "idempotency_conflict", replay.error.code
      end

      private

      def create_policy(effective_from:, effective_until:)
        result = Create.call(
          actor: @actor,
          attributes: {
            surface: "public_discovery", max_concurrent: 6, effective_from:, effective_until:
          },
          idempotency_key: "capacity-retire-create-#{SecureRandom.uuid}", reason: "Prepare retirement test"
        )
        assert_predicate result, :success?, result.error&.message
        result.value
      end

      def activate(policy)
        result = Activate.call(
          policy_id: policy.id, actor: @actor,
          idempotency_key: "capacity-retire-activate-#{policy.id}", reason: "Prepare active capacity policy"
        )
        assert_predicate result, :success?, result.error&.message
        result.value
      end

      def retire(policy, idempotency_key:, reason: "Retired preview capacity")
        assert defined?(Retire), "Marketing::PlacementCapacityPolicies::Retire should be implemented"

        Retire.call(policy_id: policy.id, actor: @actor, idempotency_key:, reason:)
      end
    end
  end
end
