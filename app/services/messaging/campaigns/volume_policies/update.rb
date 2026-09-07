# frozen_string_literal: true

require "digest"

module Messaging
  module Campaigns
    module VolumePolicies
      # Applies an auditable, idempotent quota-policy update without changing
      # the organization/channel identity selected by the administrator.
      class Update < Core::BaseService
        ALLOWED_FIELDS = %w[timezone daily_limit monthly_limit active].freeze
        PERMISSION = "messaging_campaign_volume_policy.update"

        def initialize(policy:, actor:, attributes:, idempotency_key:)
          @policy = policy
          @actor = actor
          @attributes = attributes.to_h.deep_stringify_keys.slice(*ALLOWED_FIELDS)
          @raw_idempotency_key = idempotency_key
        end

        def call
          return failure(error(:unauthorized, status: :forbidden)) unless authorized?

          key = Core::IdempotencyKey.new(@raw_idempotency_key)
          request_digest = request_digest_for(key)
          audit_key = "messaging-campaign-volume-policy-update-#{@policy.id}-#{key.digest}"
          replay = replay_result(audit_key:, request_digest:)
          return replay if replay

          persist!(key:, audit_key:, request_digest:)
          success(@policy)
        rescue ArgumentError => exception
          failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:campaign_quota_invalid, message: exception.message,
            errors: exception.record.errors.to_hash))
        rescue ActiveRecord::RecordNotUnique
          failure(error(:idempotency_conflict, status: :conflict))
        rescue Core::Error => exception
          failure(exception)
        end

        private

        def authorized?
          @actor&.super_admin? || @actor&.has_permission?(PERMISSION)
        end

        def request_digest_for(key)
          Core::KeyedDigest.digest(
            namespace: "messaging-campaign-volume-policy-request",
            value: ActiveSupport::JSON.encode(
              policy_id: @policy.id, actor_id: @actor.id, attributes: @attributes
            )
          )
        end

        def replay_result(audit_key:, request_digest:)
          audit = Core::AuditLog.find_by(audit_key:)
          return unless audit
          return failure(error(:idempotency_conflict, status: :conflict)) unless audit.metadata["request_digest"] == request_digest

          target = CampaignVolumePolicy.find_by(id: audit.metadata["record_id"] || audit.auditable_id)
          return failure(error(:campaign_quota_invalid, status: :not_found)) unless target

          success(target)
        end

        def persist!(key:, audit_key:, request_digest:)
          ActiveRecord::Base.transaction do
            @policy.assign_attributes(
              @attributes.merge(
                "updated_by_id" => @actor.id,
                "idempotency_key_digest" => key.digest,
                "request_digest" => request_digest
              )
            )
            @policy.save!

            result = Core::Audit::Record.call(
              audit_key:, action: "messaging.campaign_volume_policy.updated",
              auditable_type: @policy.class.name, auditable_id: @policy.id,
              actor_type: @actor.class.name, actor_id: @actor.id,
              audited_changes: @policy.previous_changes.slice(*@attributes.keys),
              metadata: { "record_id" => @policy.id, "request_digest" => request_digest,
                           "idempotency_key" => key.to_s }
            )
            raise result.error if result.failure?
          end
        end

        def error(key, status: :unprocessable_entity, errors: nil, message: nil)
          Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:, errors:)
        end
      end
    end
  end
end
