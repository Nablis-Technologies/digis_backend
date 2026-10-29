# frozen_string_literal: true

module Marketing
  module PlacementCapacityPolicies
    # Activates a capacity draft only after serializing overlap checks by
    # surface, ensuring no two versions can serve the same instant.
    class Activate < Core::BaseService
      include Marketing::PlacementAdmin::CommandSupport

      RESOURCE_CLASS = PlacementCapacityPolicy
      NOT_FOUND_ERROR_KEY = :capacity_policy_not_found
      PERMISSION = "marketing_placement_capacity_policy.activate"
      AUDIT_ACTION = "marketing.placement_capacity_policy.activated"

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
            operation: "activate", actor_id: @actor.id, policy_id: policy.id, reason: @reason
          })
          audit_key = "marketing-placement-capacity-policy-activate-#{key_digest}"
          replay = replay_result(audit_key:, request_digest: digest)
          next replay if replay

          ActiveRecord::Base.transaction do
            Core::Database::AdvisoryLock.acquire!(
              "marketing", "placement_capacity_policy", policy.surface
            )
            policy = PlacementCapacityPolicy.lock.find(@policy_id)
            replay = replay_result(audit_key:, request_digest: digest)
            next replay if replay
            next failure(error(:capacity_policy_not_draft, status: :conflict)) unless policy.draft?
            next failure(error(:capacity_policy_window_overlap, status: :conflict)) if overlapping_policy?(policy)

            policy.update!(status: "active", activated_by: @actor, activated_at: @at)
            audit!(
              audit_key:, action: AUDIT_ACTION, record: policy, request_digest: digest, reason: @reason,
              previous_status: "draft"
            )
            success(policy)
          end
        end
      end

      private

      def overlapping_policy?(policy)
        scope = PlacementCapacityPolicy.where(surface: policy.surface, status: "active").where.not(id: policy.id)
        scope = scope.where("effective_from < ?", policy.effective_until) if policy.effective_until
        scope.where("effective_until IS NULL OR effective_until > ?", policy.effective_from).exists?
      end
    end
  end
end
