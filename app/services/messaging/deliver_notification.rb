# frozen_string_literal: true

module Messaging
  # Claims and delivers one channel row without holding a database lock across
  # an external call. The delivery row is the retry/reconciliation boundary.
  class DeliverNotification < Core::BaseService
    class ClaimLost < Core::BusinessError
      def initialize
        super(
          I18n.t("messaging.errors.delivery_claim_lost"),
          code: "delivery_claim_lost",
          status: :conflict
        )
      end
    end

    CLAIM_TIMEOUT = 5.minutes
    RETRY_DELAY = 30.seconds

    def initialize(delivery:)
      @delivery_id = delivery.respond_to?(:id) ? delivery.id : delivery
    end

    def call
      delivery = claim_delivery
      return success(nil) unless delivery

      definition = NotificationTypes.fetch(delivery.notification.notification_type)
      content = content_for(definition)
      adapter = provider_registry.fetch(channel: delivery.channel)
      return success(finalize_unavailable(delivery)) unless adapter

      result = adapter.deliver(
        notification: delivery.notification,
        delivery:,
        content:,
        idempotency_key: delivery.idempotency_key_digest
      )
      return failure(error(:invalid_delivery_result, :failed_dependency)) unless result.is_a?(Providers::DeliveryResult)

      success(finalize(delivery, result))
    rescue Core::Error => exception
      failure(exception)
    rescue StandardError => exception
      release_for_retry(delivery, exception) if delivery
      failure(error(:delivery_failed, :failed_dependency, message: exception.message))
    end

    private

    def claim_delivery
      NotificationDelivery.transaction do
        delivery = NotificationDelivery.includes(:notification).lock.find(@delivery_id)
        return if delivery.terminal?
        return if delivery.notification.erased?
        return if delivery.notification.available_at > Time.current
        return if delivery.scheduled_at.present? && delivery.scheduled_at > Time.current
        return if delivery.claimed_at.present? && delivery.claimed_at > CLAIM_TIMEOUT.ago

        delivery.update!(
          status: "processing",
          claimed_at: Time.current,
          attempts: delivery.attempts + 1,
          enqueue_claimed_at: nil
        )
        delivery
      end
    end

    def provider_registry
      Rails.application.config.x.messaging_provider_registry
    end

    def content_for(definition)
      {
        title: I18n.t("messaging.notifications.#{definition.key}.title"),
        body: I18n.t("messaging.notifications.#{definition.key}.body")
      }
    end

    def finalize_unavailable(delivery)
      update_claimed(delivery, status: "unavailable", claimed_at: nil)
    end

    def finalize(delivery, result)
      attributes = if result.success?
        {
          status: result.status,
          provider: result.provider,
          provider_message_id: result.provider_message_id,
          sent_at: Time.current,
          delivered_at: result.status == "delivered" ? Time.current : nil,
          claimed_at: nil,
          next_attempt_at: nil,
          failure_code: nil,
          failure_detail: nil,
          enqueue_claimed_at: nil
        }
      elsif result.retryable
        {
          status: "pending",
          provider: result.provider,
          next_attempt_at: RETRY_DELAY.from_now,
          claimed_at: nil,
          failure_code: result.failure_code,
          failure_detail: sanitize(result.failure_detail),
          enqueue_claimed_at: nil
        }
      else
        {
          status: "failed",
          provider: result.provider,
          failed_at: Time.current,
          claimed_at: nil,
          failure_code: result.failure_code,
          failure_detail: sanitize(result.failure_detail),
          enqueue_claimed_at: nil
        }
      end
      update_claimed(delivery, **attributes)
    end

    def release_for_retry(delivery, exception)
      update_claimed(
        delivery,
        status: "pending",
        next_attempt_at: RETRY_DELAY.from_now,
        claimed_at: nil,
        enqueue_claimed_at: nil,
        failure_code: "provider_error",
        failure_detail: sanitize(exception.message)
      )
    end

    def update_claimed(delivery, **attributes)
      updated = NotificationDelivery
        .where(id: delivery.id, status: "processing", claimed_at: delivery.claimed_at)
        .update_all(attributes.merge(updated_at: Time.current))
      return delivery.reload if updated == 1

      raise ClaimLost
    end

    def sanitize(detail)
      detail.to_s.gsub(/(?:authorization|password|secret|token)\s*[:=]\s*\S+/i, "[REDACTED]").first(500).presence
    end

    def error(key, status, message: nil, errors: nil)
      Core::BusinessError.new(
        message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:, errors:
      )
    end
  end
end
