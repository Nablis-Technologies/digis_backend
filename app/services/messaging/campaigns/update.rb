# frozen_string_literal: true

module Messaging
  module Campaigns
    # Updates composition and audience inputs while the campaign is still draft.
    class Update < Core::BaseService
      ALLOWED_FIELDS = %w[name timezone event_id message_subject message_body variables metadata].freeze
      QUOTE_INVALIDATING_FIELDS = %w[timezone event_id message_subject message_body variables metadata].freeze
      QUOTE_FIELDS = {
        "quoted_rate_version_id" => nil,
        "quoted_quantity" => nil,
        "quoted_unit_price_minor" => nil,
        "quote_digest" => nil,
        "quoted_at" => nil,
        "quote_expires_at" => nil
      }.freeze

      def initialize(campaign:, actor:, attributes:, idempotency_key:)
        @campaign = campaign
        @actor = actor
        @attributes = attributes.to_h.stringify_keys.slice(*ALLOWED_FIELDS)
        @raw_idempotency_key = idempotency_key
      end

      def call
        Core::IdempotencyKey.new(@raw_idempotency_key)
        return failure(error(:unauthorized, status: :forbidden)) unless Events::AuthorizationResolver.organization_admin?(@actor, @campaign.organization)
        return failure(error(:campaign_invalid_state, status: :conflict)) unless @campaign.status == "draft"

        ActiveRecord::Base.transaction do
          campaign = Campaign.lock.find(@campaign.id)
          return failure(error(:campaign_invalid_state, status: :conflict)) unless campaign.status == "draft"

          campaign.audience_snapshot&.destroy! if audience_inputs_changed?
          campaign.update!(@attributes.merge(quote_invalidated_attributes))
          success(campaign)
        end
      rescue ArgumentError => exception
        failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:campaign_audience_invalid, message: exception.message))
      rescue ActiveRecord::RecordNotUnique
        failure(error(:campaign_name_taken, status: :conflict))
      end

      private

      def audience_inputs_changed?
        @attributes.key?("event_id") || @attributes.key?("metadata")
      end

      def quote_invalidated_attributes
        return {} unless @attributes.keys.intersect?(QUOTE_INVALIDATING_FIELDS)

        QUOTE_FIELDS
      end

      def error(key, message: nil, status: :unprocessable_entity)
        Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
