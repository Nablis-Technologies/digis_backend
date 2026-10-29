# frozen_string_literal: true

module Messaging
  module Campaigns
    # Creates a draft with an organization-owned, immutable channel choice.
    class Create < Core::BaseService
      def initialize(organization:, actor:, name:, channel:, timezone:, idempotency_key:,
        event_id: nil, message_subject: nil, message_body: nil, variables: {}, metadata: {})
        @organization = organization
        @actor = actor
        @name = name.to_s.strip
        @channel = channel.to_s.strip.downcase
        @timezone = timezone.to_s.strip
        @event_id = event_id
        @message_subject = message_subject
        @message_body = message_body
        @variables = variables.to_h.stringify_keys
        @metadata = metadata.to_h.stringify_keys
        @key = Core::IdempotencyKey.new(idempotency_key)
      end

      def call
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?
        return failure(error(:campaign_name_required)) if @name.blank?
        return failure(error(:campaign_audience_invalid)) unless Campaign::CHANNELS.include?(@channel)

        existing = Campaign.find_by(organization: @organization, name: @name)
        return replay(existing) if existing

        campaign = Campaign.create!(
          organization: @organization, created_by: @actor, event_id: @event_id,
          name: @name, channel: @channel, timezone: @timezone,
          message_subject: @message_subject, message_body: @message_body, variables: @variables,
          metadata: @metadata.merge("create_idempotency_key_digest" => @key.digest)
        )
        success(campaign)
      rescue ArgumentError => exception
        failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:campaign_audience_invalid, message: exception.message))
      rescue ActiveRecord::RecordNotUnique
        replay(Campaign.find_by!(organization: @organization, name: @name))
      end

      private

      def authorized?
        Events::AuthorizationResolver.organization_admin?(@actor, @organization)
      end

      def replay(existing)
        return failure(error(:campaign_audience_invalid)) unless existing
        return success(existing) if existing.metadata.to_h["create_idempotency_key_digest"] == @key.digest

        failure(error(:idempotency_conflict, status: :conflict))
      end

      def error(key, message: nil, status: :unprocessable_entity)
        Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
