# frozen_string_literal: true

module Marketing
  module PlacementCapacityPolicies
    # Creates immutable capacity-policy drafts and assigns versions per
    # surface under the same lock used by activation.
    class Create < Core::BaseService
      include Marketing::PlacementAdmin::CommandSupport

      RESOURCE_CLASS = PlacementCapacityPolicy
      NOT_FOUND_ERROR_KEY = :capacity_policy_not_found
      PERMISSION = "marketing_placement_capacity_policy.create"
      AUDIT_ACTION = "marketing.placement_capacity_policy.created"

      def initialize(actor:, attributes:, idempotency_key:, reason:)
        @actor = actor
        @attributes = attributes
        @raw_idempotency_key = idempotency_key
        @reason = reason.to_s.strip
      end

      def call
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?(PERMISSION)
        return failure(error(:reason_required)) if @reason.blank?

        handle_errors do
          key_digest = idempotency_digest
          attributes = canonical_attributes
          digest = request_digest({ actor_id: @actor.id, attributes:, reason: @reason })
          audit_key = "marketing-placement-capacity-policy-create-#{key_digest}"
          replay = replay_result(audit_key:, request_digest: digest)
          next replay if replay

          ActiveRecord::Base.transaction do
            Core::Database::AdvisoryLock.acquire!(
              "marketing", "placement_capacity_policy", attributes.fetch(:surface)
            )
            replay = replay_result(audit_key:, request_digest: digest)
            next replay if replay

            policy = PlacementCapacityPolicy.create!(
              attributes.merge(
                version: next_version(attributes.fetch(:surface)), status: "draft", created_by: @actor,
                idempotency_key_digest: key_digest, request_digest: digest
              )
            )
            audit!(audit_key:, action: AUDIT_ACTION, record: policy, request_digest: digest, reason: @reason)
            success(policy)
          end
        end
      end

      private

      def canonical_attributes
        source = @attributes.respond_to?(:to_unsafe_h) ? @attributes.to_unsafe_h : @attributes.to_h
        fields = source.deep_symbolize_keys.slice(:surface, :max_concurrent, :effective_from, :effective_until)
        fields[:surface] = fields[:surface].to_s.strip.downcase
        fields
      end

      def next_version(surface)
        PlacementCapacityPolicy.where(surface:).maximum(:version).to_i + 1
      end
    end
  end
end
