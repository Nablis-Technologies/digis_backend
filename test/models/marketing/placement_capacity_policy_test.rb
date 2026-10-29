# frozen_string_literal: true

require "test_helper"

module Marketing
  class PlacementCapacityPolicyTest < ActiveSupport::TestCase
    test "capacity policy table has versioned lifecycle and audit fields" do
      connection = ActiveRecord::Base.connection
      exists = connection.data_source_exists?("marketing_placement_capacity_policies")
      assert exists
      return unless exists

      columns = connection.columns("marketing_placement_capacity_policies").map(&:name)
      %w[surface version max_concurrent status effective_from effective_until created_by_id
        activated_by_id retired_by_id activated_at retired_at idempotency_key_digest request_digest].each do |column|
        assert_includes columns, column
      end
    end

    test "accepts draft active and retired lifecycle metadata" do
      draft = build_policy(status: "draft", activated_by: nil, activated_at: nil)
      active = build_policy
      retired = build_policy(
        status: "retired", retired_by: core_users(:super_admin), retired_at: Time.current
      )

      [ draft, active, retired ].each do |policy|
        assert_predicate policy, :valid?, policy.errors.full_messages.join(", ")
      end
    end

    test "bounds concurrent placement capacity from one through the hard serving ceiling" do
      [ 1, 100 ].each do |limit|
        assert_predicate build_policy(max_concurrent: limit), :valid?
      end

      [ 0, 101 ].each do |limit|
        policy = build_policy(max_concurrent: limit)

        assert_not policy.valid?
        assert_includes policy.errors.attribute_names, :max_concurrent
      end
    end

    test "rejects unsupported surfaces and non-positive effective windows" do
      unsupported = build_policy(surface: "organizer_dashboard")
      invalid_window = build_policy(effective_until: Time.current - 2.hours)

      assert_not unsupported.valid?
      assert_includes unsupported.errors.attribute_names, :surface
      assert_not invalid_window.valid?
      assert_includes invalid_window.errors.attribute_names, :effective_until
    end

    test "versions are unique within a surface" do
      create_policy(version: 1)
      duplicate = build_policy(version: 1)

      assert_not duplicate.valid?
      assert_includes duplicate.errors.attribute_names, :version
    end

    test "active_for resolves an effective policy using a half-open interval" do
      policy = create_policy(effective_from: Time.current - 1.hour, effective_until: Time.current + 1.hour)

      assert_respond_to PlacementCapacityPolicy, :active_for
      assert_equal policy, PlacementCapacityPolicy.active_for(surface: policy.surface, at: policy.effective_from)
      assert_nil PlacementCapacityPolicy.active_for(surface: policy.surface, at: policy.effective_until)
    end

    test "active_for surfaces overlapping active policies as an integrity error" do
      first = create_policy(version: 1)
      create_policy(version: 2, effective_from: first.effective_from + 1.minute)

      assert_respond_to PlacementCapacityPolicy, :active_for
      assert_raises(PlacementCapacityPolicy::AmbiguousActivePoliciesError) do
        PlacementCapacityPolicy.active_for(surface: first.surface, at: Time.current)
      end
    end

    test "capacity digests are not searchable through ransack" do
      searchable = PlacementCapacityPolicy.ransackable_attributes

      refute_includes searchable, "idempotency_key_digest"
      refute_includes searchable, "request_digest"
    end

    private

    def build_policy(**overrides)
      PlacementCapacityPolicy.new({
        surface: "public_discovery", version: SecureRandom.random_number(1_000_000) + 1,
        max_concurrent: 1, status: "active", effective_from: 1.hour.ago, effective_until: 1.hour.from_now,
        created_by: core_users(:super_admin), activated_by: core_users(:super_admin), activated_at: Time.current,
        idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32)
      }.merge(overrides))
    end

    def create_policy(**attributes)
      build_policy(**attributes).tap(&:save!)
    end
  end
end
