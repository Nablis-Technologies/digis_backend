# frozen_string_literal: true

require "test_helper"

module Marketing
  module PlacementCapacityPolicies
    class ActivateTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @actor = core_users(:super_admin)
        @create_keys = []
      end

      teardown do
        digests = @create_keys.map do |key|
          Core::KeyedDigest.digest(namespace: "marketing-placement-admin-idempotency", value: key)
        end
        policy_ids = PlacementCapacityPolicy.where(idempotency_key_digest: digests).pluck(:id)
        Core::AuditLog.where(
          auditable_type: "Marketing::PlacementCapacityPolicy", auditable_id: policy_ids
        ).delete_all
        PlacementCapacityPolicy.where(id: policy_ids).delete_all
      end

      test "activates future policies and resolves them only inside their effective interval" do
        start_at = 2.days.from_now
        policy = create_policy(effective_from: start_at, effective_until: start_at + 3.days)

        result = activate(policy)

        assert_predicate result, :success?, result.error&.message
        assert_equal "active", result.value.status
        assert_equal @actor.id, result.value.activated_by_id
        assert_not_nil result.value.activated_at
        assert_nil PlacementCapacityPolicy.active_for(surface: policy.surface, at: start_at - 1.second)
        assert_equal policy.id, PlacementCapacityPolicy.active_for(surface: policy.surface, at: start_at).id
        audit = Core::AuditLog.find_by!(action: "marketing.placement_capacity_policy.activated", auditable_id: policy.id)
        assert_equal "Activated preview capacity", audit.metadata.fetch("reason")
      end

      test "rejects overlapping active policies for one surface and instant" do
        start_at = 2.days.from_now
        first = create_policy(effective_from: start_at, effective_until: start_at + 3.days)
        second = create_policy(effective_from: start_at + 2.days, effective_until: start_at + 4.days)
        assert_predicate activate(first), :success?

        result = activate(second, idempotency_key: "capacity-overlap-#{SecureRandom.uuid}")

        assert_predicate result, :failure?
        assert_equal "capacity_policy_window_overlap", result.error.code
        assert_equal "draft", second.reload.status
      end

      test "allows adjacent half-open policies and protects immutable policy terms" do
        start_at = 2.days.from_now
        first = create_policy(effective_from: start_at, effective_until: start_at + 3.days)
        second = create_policy(effective_from: first.effective_until, effective_until: first.effective_until + 2.days)
        assert_predicate activate(first), :success?

        adjacent = activate(second, idempotency_key: "capacity-adjacent-#{SecureRandom.uuid}")
        second.max_concurrent = 8

        assert_predicate adjacent, :success?, adjacent.error&.message
        assert_not second.valid?
        assert_includes second.errors.attribute_names, :max_concurrent
      end

      test "same-key activation replay is idempotent and a different key cannot reactivate" do
        policy = create_policy(effective_from: 1.day.ago, effective_until: 2.days.from_now)
        operation = -> { activate(policy, idempotency_key: "capacity-activate-replay-#{policy.id}") }
        assert_audit_idempotent(
          operation, action: "marketing.placement_capacity_policy.activated",
          auditable_type: "Marketing::PlacementCapacityPolicy", auditable_id: policy.id
        )

        assert_predicate operation.call, :success?
        conflict = activate(policy, idempotency_key: "capacity-activate-again-#{policy.id}")

        assert_predicate conflict, :failure?
        assert_equal "capacity_policy_not_draft", conflict.error.code
      end

      test "missing policy ids return a typed not-found result" do
        result = Activate.call(
          policy_id: SecureRandom.uuid, actor: @actor,
          idempotency_key: "capacity-activate-missing", reason: "Missing policy test"
        )

        assert_predicate result, :failure?
        assert_equal "capacity_policy_not_found", result.error.code
        assert_equal :not_found, result.error.status
      end

      test "serializes concurrent overlapping policy activation on a surface" do
        assert defined?(Activate), "Marketing::PlacementCapacityPolicies::Activate should be implemented"

        start_at = 2.days.from_now
        first = create_policy(effective_from: start_at, effective_until: start_at + 3.days)
        second = create_policy(effective_from: start_at, effective_until: start_at + 3.days)
        policy_ids = [ first.id, second.id ]

        race = Prosopite.pause do
          run_database_race do |index|
            policy_id = policy_ids.fetch(index)
            Activate.call(
              policy_id:, actor: Core::User.find(@actor.id),
              idempotency_key: "capacity-concurrent-activate-#{policy_id}", reason: "Concurrent capacity activation"
            )
          end
        end
        results = race.results

        assert_empty race.errors, race.errors.inspect
        assert_equal 1, results.count(&:success?)
        assert_equal 1, results.count(&:failure?)
        assert_equal "capacity_policy_window_overlap", results.find(&:failure?).error.code
        assert_equal [ "active", "draft" ], PlacementCapacityPolicy.where(id: policy_ids).order(:status).pluck(:status)
      end

      private

      def create_policy(effective_from:, effective_until:, surface: "public_discovery", max_concurrent: 6)
        key = "capacity-activate-create-#{SecureRandom.uuid}"
        @create_keys << key
        result = Create.call(
          actor: @actor,
          attributes: { surface:, max_concurrent:, effective_from:, effective_until: },
          idempotency_key: key, reason: "Prepare capacity activation"
        )
        assert_predicate result, :success?, result.error&.message
        result.value
      end

      def activate(policy, idempotency_key: "capacity-activate-#{policy.id}")
        assert defined?(Activate), "Marketing::PlacementCapacityPolicies::Activate should be implemented"

        Activate.call(policy_id: policy.id, actor: @actor, idempotency_key:, reason: "Activated preview capacity")
      end
    end
  end
end
