# frozen_string_literal: true

module Messaging
  module Campaigns
    # Shares request-bound audit and replay rules for lifecycle transitions.
    module LifecycleCommandSupport
      private

      def lifecycle_request_digest(action:, key:, reason: nil)
        Core::KeyedDigest.digest(
          namespace: "messaging-campaign-#{action}-request",
          value: ActiveSupport::JSON.encode(
            { campaign_id: @campaign.id, actor_id: @actor.id, reason: }.compact
          )
        )
      end

      def lifecycle_audit_key(action:, key:)
        "messaging-campaign-#{action}-#{@campaign.id}-#{key.digest}"
      end

      def lifecycle_replay(audit_key:, request_digest:, campaign:)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit
        return failure(error(:idempotency_conflict, status: :conflict)) unless
          audit.metadata.to_h["request_digest"] == request_digest

        success(campaign)
      end

      def record_lifecycle_audit!(action:, audit_key:, request_digest:, key:, campaign:, from:, to:, reason: nil)
        result = Core::Audit::Record.call(
          audit_key:, action:, auditable_type: campaign.class.name, auditable_id: campaign.id,
          actor_type: @actor.class.name, actor_id: @actor.id,
          audited_changes: { "status" => [ from, to ] }.merge(reason.present? ? { "reason" => reason } : {}),
          metadata: {
            "campaign_id" => campaign.id, "request_digest" => request_digest, "idempotency_key" => key.to_s
          }
        )
        raise result.error if result.failure?

        result.value
      end
    end
  end
end
