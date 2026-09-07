# frozen_string_literal: true

require "digest"

module Messaging
  module Campaigns
    module Templates
      # Creates or updates a scoped template with an audit-backed idempotency
      # boundary. Template versions remain immutable content rows.
      class Upsert < Core::BaseService
        PERMISSIONS = {
          "create" => "messaging_campaign_template.create",
          "update" => "messaging_campaign_template.update"
        }.freeze

        def initialize(template:, actor:, attributes:, idempotency_key:, action:, organization: nil)
          @template = template
          @actor = actor
          @organization = organization
          @attributes = attributes.to_h.deep_stringify_keys.slice("name", "channel", "status", "metadata")
          @raw_idempotency_key = idempotency_key
          @action = action.to_s
        end

        def call
          return failure(error(:unauthorized, status: :forbidden)) unless authorized?

          key = Core::IdempotencyKey.new(@raw_idempotency_key)
          request_digest = request_digest_for(key)
          audit_key = "messaging-campaign-template-#{@action}-#{key.digest}"
          replay = replay_result(audit_key:, request_digest:)
          return replay if replay

          persist!(audit_key:, request_digest:)
          success(@template)
        rescue ArgumentError => exception
          failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:campaign_template_invalid, message: exception.message,
            errors: exception.record.errors.to_hash))
        rescue ActiveRecord::RecordNotUnique
          failure(error(:campaign_template_name_taken, status: :conflict))
        rescue Core::Error => exception
          failure(exception)
        end

        private

        def authorized?
          return Events::AuthorizationResolver.organization_admin?(@actor, @organization) if @organization

          @actor&.super_admin? || @actor&.has_permission?(PERMISSIONS.fetch(@action))
        end

        def request_digest_for(key)
          Core::KeyedDigest.digest(
            namespace: "messaging-campaign-template-admin-request",
            value: ActiveSupport::JSON.encode(
              action: @action, actor_id: @actor.id, template_id: @template.id,
              organization_id: @organization&.id, attributes: @attributes
            )
          )
        end

        def replay_result(audit_key:, request_digest:)
          audit = Core::AuditLog.find_by(audit_key:)
          return unless audit
          return failure(error(:idempotency_conflict, status: :conflict)) unless audit.metadata["request_digest"] == request_digest

          target = CampaignTemplate.find_by(id: audit.metadata["record_id"] || audit.auditable_id)
          return failure(error(:campaign_template_invalid, status: :not_found)) unless target

          success(target)
        end

        def persist!(audit_key:, request_digest:)
          ActiveRecord::Base.transaction do
            @template.assign_attributes(@attributes)
            @template.organization = @organization
            @template.created_by = @actor if @template.new_record?
            @template.save!

            result = Core::Audit::Record.call(
              audit_key:, action: "messaging.campaign_template.#{@action}",
              auditable_type: @template.class.name, auditable_id: @template.id,
              actor_type: @actor.class.name, actor_id: @actor.id,
              audited_changes: @template.previous_changes.slice(*@attributes.keys),
              metadata: { "record_id" => @template.id, "request_digest" => request_digest }
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
