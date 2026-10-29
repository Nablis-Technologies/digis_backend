# frozen_string_literal: true

require "digest"

module Messaging
  # Applies a user's complete channel-choice request and records its request
  # identity through Core::Audit::Record so retries cannot change the payload.
  class UpdatePreferences < Core::BaseService
    def initialize(user:, preferences:, idempotency_key:)
      @user = user
      @preferences = Array(preferences)
      @idempotency_key = idempotency_key
    end

    def call
      key = Core::IdempotencyKey.new(@idempotency_key)
      normalized = normalize_preferences
      validate_preferences!(normalized)
      request_digest = Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(normalized))
      record_request!(key:, normalized:, request_digest:)

      Messaging::NotificationPreference.transaction do
        normalized.each do |attributes|
          preference = Messaging::NotificationPreference.find_or_initialize_by(
            user_id: @user.id,
            category: attributes.fetch("category"),
            channel: attributes.fetch("channel")
          )
          preference.enabled = attributes.fetch("enabled")
          preference.save!
        end
      end

      success(Messaging::NotificationPreference.effective_for(@user))
    rescue Core::Audit::Record::ReplayConflict
      failure(error(:notification_idempotency_conflict, :conflict))
    rescue Core::BusinessError => exception
      failure(exception)
    rescue ArgumentError => exception
      failure(error(:invalid_idempotency_key, :unprocessable_entity, message: exception.message))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:notification_preference_invalid, :unprocessable_entity, errors: exception.record.errors.to_hash))
    end

    private

    def normalize_preferences
      @preferences.map do |entry|
        attributes = entry.to_h.deep_stringify_keys
        {
          "category" => attributes.fetch("category").to_s.strip.downcase,
          "channel" => attributes.fetch("channel").to_s.strip.downcase,
          "enabled" => ActiveModel::Type::Boolean.new.cast(attributes.fetch("enabled"))
        }
      end.sort_by { |attributes| [ attributes.fetch("category"), attributes.fetch("channel") ] }
    rescue KeyError, TypeError
      raise ArgumentError, I18n.t("messaging.errors.notification_preference_invalid")
    end

    def validate_preferences!(preferences)
      preferences.each do |attributes|
        category = attributes.fetch("category")
        channel = attributes.fetch("channel")
        unless Messaging::Notification::CATEGORIES.include?(category) &&
            Messaging::NotificationDelivery::CHANNELS.include?(channel)
          raise ArgumentError, I18n.t("messaging.errors.notification_preference_invalid")
        end
        if category.in?(%w[security credential legal]) && channel == "in_app" && !attributes.fetch("enabled")
          raise error(:notification_preference_mandatory, :unprocessable_entity)
        end
      end
    end

    def record_request!(key:, normalized:, request_digest:)
      result = Core::Audit::Record.call(
        audit_key: "messaging-notification-preferences-#{@user.id}-#{key.digest}",
        action: "messaging.notification_preferences.updated",
        auditable_type: @user.class.name,
        auditable_id: @user.id,
        actor_type: @user.class.name,
        actor_id: @user.id,
        audited_changes: { preferences: normalized },
        metadata: { request_digest: }
      )
      raise result.error if result.failure?
    end

    def error(key, status, errors: nil, message: nil)
      Core::BusinessError.new(
        message || I18n.t("messaging.errors.#{key}"),
        code: key.to_s,
        status:,
        errors:
      )
    end
  end
end
