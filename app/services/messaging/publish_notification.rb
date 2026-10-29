# frozen_string_literal: true

require "digest"

module Messaging
  # Persists one recipient-owned notification and its channel rows. The unique
  # user/dedupe boundary makes outbox replay safe; no provider is called here.
  class PublishNotification < Core::BaseService
    def initialize(type:, recipient:, source:, data:, dedupe_key:, available_at: Time.current)
      @type = type.to_s
      @recipient = recipient
      @source = source
      @data = data
      @dedupe_key = dedupe_key.to_s.strip
      @available_at = available_at
    end

    def call
      return failure(error(:recipient_required, :unprocessable_entity)) unless @recipient.is_a?(Core::User)
      return failure(error(:dedupe_key_missing, :unprocessable_entity)) if @dedupe_key.blank?

      definition = NotificationTypes.fetch(@type)
      projection = NotificationProjection.call(@type, @data)
      policy = retention_policy
      return failure(error(:retention_policy_missing, :failed_dependency)) unless policy

      notification = persist_notification(
        definition:, projection:, policy:
      )
      success(notification)
    rescue Core::BusinessError => exception
      failure(exception)
    rescue Core::Error => exception
      failure(exception)
    rescue ArgumentError => exception
      failure(error(:invalid_notification, :unprocessable_entity, message: exception.message))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:invalid_notification, :unprocessable_entity, errors: exception.record.errors.to_hash))
    end

    private

    def retention_policy
      Core::DataRetentionPolicy
        .active
        .effective_at(Time.current)
        .where(category: "messaging_notification")
        .order(version: :desc)
        .first
    end

    def persist_notification(definition:, projection:, policy:)
      notification = nil
      Messaging::Notification.transaction do
      notification = Messaging::Notification.create_or_find_by!(
          user_id: @recipient.id,
          dedupe_key: @dedupe_key
        ) do |row|
          row.assign_attributes(
            notification_type: definition.key,
            category: definition.category,
            source: @source,
            data: projection,
            retention_policy: policy,
            retain_until: retain_until_for(policy),
            available_at: @available_at
          )
        end
        verify_replay!(notification, definition:, projection:) unless notification.previous_changes.key?("id")
        ensure_deliveries!(notification, definition:)
      end
      notification
    end

    def retain_until_for(policy)
      return unless policy.retention_days.present?

      @available_at + policy.retention_days.days
    end

    def verify_replay!(notification, definition:, projection:)
      same = notification.notification_type == definition.key &&
        notification.category == definition.category &&
        notification.source_type == @source&.class&.base_class&.name &&
        notification.source_id == @source&.id &&
        notification.projection_digest == projection_digest(projection)
      return if same

      raise error(:notification_idempotency_conflict, :conflict)
    end

    def ensure_deliveries!(notification, definition:)
      preferences = NotificationPreference
        .where(user_id: notification.user_id, category: definition.category)
        .index_by(&:channel)
      existing = NotificationDelivery.where(notification_id: notification.id).index_by(&:channel)
      now = Time.current
      rows = definition.channels.filter_map do |channel|
        next if existing.key?(channel)

        preference = preferences[channel]
        status = if preference&.enabled == false && !(definition.mandatory? && channel == "in_app")
          "suppressed"
        else
          "pending"
        end
        digest = Core::KeyedDigest.digest(
          namespace: "messaging-notification-delivery",
          value: "#{notification.id}:#{channel}"
        )
        {
          notification_id: notification.id,
          channel:,
          status:,
          idempotency_key_digest: digest,
          scheduled_at: notification.available_at,
          created_at: now,
          updated_at: now
        }
      end
      NotificationDelivery.insert_all(
        rows,
        unique_by: :idx_messaging_notification_deliveries_notification_channel
      ) if rows.any?
      notification.association(:deliveries).reset
    end

    def projection_digest(value)
      Messaging::Notification.projection_digest_for(value)
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
