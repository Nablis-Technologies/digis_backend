# frozen_string_literal: true

module Marketing
  module PlacementCapacityPolicies
    # Retires a draft or active policy for future admission decisions; existing
    # paid placements are not coupled to the current capacity configuration.
    class Retire < Core::BaseService
      include Marketing::PlacementAdmin::CommandSupport

      RESOURCE_CLASS = PlacementCapacityPolicy
      NOT_FOUND_ERROR_KEY = :capacity_policy_not_found
      PERMISSION = "marketing_placement_capacity_policy.retire"
      AUDIT_ACTION = "marketing.placement_capacity_policy.retired"

      def initialize(policy_id:, actor:, idempotency_key:, reason:, at: Time.current)
        @policy_id = policy_id
        @actor = actor
        @raw_idempotency_key = idempotency_key
        @reason = reason.to_s.strip
        @at = at.to_time.utc
      end

      def call
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?(PERMISSION)
        return failure(error(:reason_required)) if @reason.blank?

        handle_errors do
          policy = PlacementCapacityPolicy.find(@policy_id)
          key_digest = idempotency_digest
          digest = request_digest({
            operation: "retire", actor_id: @actor.id, policy_id: policy.id, reason: @reason
          })
          audit_key = "marketing-placement-capacity-policy-retire-#{key_digest}"
          replay = replay_result(audit_key:, request_digest: digest)
          next replay if replay

          ActiveRecord::Base.transaction do
            Core::Database::AdvisoryLock.acquire!(
              "marketing", "placement_capacity_policy", policy.surface
            )
            policy = PlacementCapacityPolicy.lock.find(@policy_id)
            replay = replay_result(audit_key:, request_digest: digest)
            next replay if replay
            next failure(error(:capacity_policy_not_retirable, status: :conflict)) unless policy.draft? || policy.active?

            previous_status = policy.status
            policy.update!(status: "retired", retired_by: @actor, retired_at: @at)
            audit!(
              audit_key:, action: AUDIT_ACTION, record: policy, request_digest: digest, reason: @reason,
              previous_status:
            )
            success(policy)
          end
        end
      end
    end
  end
end
