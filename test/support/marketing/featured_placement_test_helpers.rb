# frozen_string_literal: true

module Marketing
  # Builds persisted active capacity fixtures so runtime tests exercise the
  # same database-backed policy source as production.
  module FeaturedPlacementTestHelpers
    def create_active_capacity_policy!(max_concurrent:, surface: "public_discovery",
      effective_from: 1.hour.ago, effective_until: 30.days.from_now)
      actor = core_users(:super_admin)
      PlacementCapacityPolicy.create!(
        surface:, version: PlacementCapacityPolicy.where(surface:).maximum(:version).to_i + 1,
        max_concurrent:, status: "active", effective_from:, effective_until:, created_by: actor,
        activated_by: actor, activated_at: Time.current,
        idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32)
      )
    end

    def retire_capacity_policy_for_test!(policy)
      # Test setup transitions a seeded policy to the retired state without
      # exercising the admin command whose behavior has its own test suite.
      policy.update_columns(
        status: "retired", retired_by_id: core_users(:super_admin).id,
        retired_at: Time.current, updated_at: Time.current
      )
      policy
    end

    def replace_active_capacity_policy!(max_concurrent:, surface: "public_discovery")
      current = PlacementCapacityPolicy.active_for(surface:, at: Time.current)
      retire_capacity_policy_for_test!(current) if current
      create_active_capacity_policy!(max_concurrent:, surface:)
    end
  end
end
