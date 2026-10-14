# frozen_string_literal: true

require "test_helper"

module Marketing
  module PlacementCapacityPolicies
    class CreateTest < ActiveSupport::TestCase
      setup do
        @actor = core_users(:super_admin)
        @attributes = {
          surface: "public_discovery", max_concurrent: 6,
          effective_from: 1.hour.ago, effective_until: 30.days.from_now, version: 800
        }
      end

      test "creates a draft and assigns a monotonically increasing surface version" do
        first = create_policy
        second = create_policy(idempotency_key: "capacity-version-second")

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal [ first.value.version + 1 ], [ second.value.version ]
        assert_equal "draft", first.value.status
        assert_equal @actor.id, first.value.created_by_id
        assert_equal 6, first.value.max_concurrent
      end

      test "rejects a capacity above the shared hard ceiling" do
        result = create_policy(attributes: @attributes.merge(max_concurrent: 101),
          idempotency_key: "capacity-invalid-over-ceiling")

        assert_predicate result, :failure?
        assert_equal "invalid_placement_capacity_policy", result.error.code
      end

      test "replays the original draft without allocating another version or audit" do
        first = nil
        operation = lambda do
          result = create_policy(idempotency_key: "capacity-create-replay")
          first ||= result
          result
        end
        assert_idempotent(operation, counter: -> { PlacementCapacityPolicy.count })

        replay = operation.call

        assert_equal first.value.id, replay.value.id
        audit = Core::AuditLog.find_by!(
          action: "marketing.placement_capacity_policy.created", auditable_id: first.value.id
        )
        assert_equal "Created preview capacity", audit.metadata.fetch("reason")
        assert_equal first.value.id, audit.auditable_id
        refute audit.metadata.key?("placement_capacity_policy_id")
        audit.update!(metadata: audit.metadata.except("placement_capacity_policy_id"))

        replay_without_metadata_id = operation.call

        assert_predicate replay_without_metadata_id, :success?, replay_without_metadata_id.error&.message
        assert_equal first.value.id, replay_without_metadata_id.value.id
      end

      test "rejects replay when the audit row belongs to a different resource type" do
        first = create_policy(idempotency_key: "capacity-create-wrong-auditable-type")
        audit = Core::AuditLog.find_by!(
          action: "marketing.placement_capacity_policy.created", auditable_id: first.value.id
        )
        audit.update!(auditable_type: "Marketing::PlacementOffer")

        replay = create_policy(idempotency_key: "capacity-create-wrong-auditable-type")

        assert_predicate replay, :failure?
        assert_equal "idempotency_conflict", replay.error.code
      end

      test "rejects changed capacity under the same idempotency key" do
        first = create_policy(idempotency_key: "capacity-create-conflict")
        second = create_policy(
          attributes: @attributes.merge(max_concurrent: 8), idempotency_key: "capacity-create-conflict"
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "idempotency_conflict", second.error.code
      end

      test "database uniqueness remains the surface version race backstop" do
        result = create_policy(idempotency_key: "capacity-create-unique-index")
        attributes = result.value.attributes.merge(
          "id" => SecureRandom.uuid,
          "idempotency_key_digest" => SecureRandom.hex(32),
          "request_digest" => SecureRandom.hex(32)
        )

        assert_raises(ActiveRecord::RecordNotUnique) do
          PlacementCapacityPolicy.insert_all!([ attributes ])
        end
      end

      private

      def create_policy(actor: @actor, attributes: @attributes, idempotency_key: "capacity-create-default",
        reason: "Created preview capacity")
        assert defined?(Create), "Marketing::PlacementCapacityPolicies::Create should be implemented"

        Create.call(actor:, attributes:, idempotency_key:, reason:)
      end
    end

    class CreateConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @actor = core_users(:super_admin)
        @race_scope = SecureRandom.hex(8)
        @keys = 2.times.map { "capacity-version-race-#{@race_scope}-#{SecureRandom.uuid}" }
      end

      teardown do
        digests = @keys.map do |key|
          Core::KeyedDigest.digest(namespace: "marketing-placement-admin-idempotency", value: key)
        end
        policy_ids = PlacementCapacityPolicy.where(idempotency_key_digest: digests).pluck(:id)
        Core::AuditLog.where(
          auditable_type: "Marketing::PlacementCapacityPolicy", auditable_id: policy_ids
        ).delete_all
        PlacementCapacityPolicy.where(id: policy_ids).delete_all
      end

      test "serializes concurrent same-surface draft creation into unique sequential versions" do
        assert defined?(Create), "Marketing::PlacementCapacityPolicies::Create should be implemented"

        results = Prosopite.pause do
          race = run_database_race do |index|
            Create.call(
              actor: Core::User.find(@actor.id),
              attributes: {
                surface: "public_discovery", max_concurrent: 6,
                effective_from: 1.hour.ago, effective_until: 30.days.from_now
              },
              idempotency_key: @keys.fetch(index), reason: "Concurrent capacity version"
            )
          end
          assert_empty race.errors, race.errors.inspect
          race.results
        end

        assert results.all?(&:success?), results.map { |result| result.error&.message }.inspect
        assert_equal 2, results.map { |result| result.value.version }.uniq.length
        assert_equal 1, results.map { |result| result.value.version }.max - results.map { |result| result.value.version }.min
      end
    end
  end
end
