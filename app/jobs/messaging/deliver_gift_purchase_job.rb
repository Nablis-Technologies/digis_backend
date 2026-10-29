# frozen_string_literal: true

module Messaging
  # Delivers one paid gift capability. Only the durable gift ID is queued;
  # recipient contact, note, and bearer token are decrypted inside this job.
  class DeliverGiftPurchaseJob < ApplicationJob
    queue_as :notifications
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(gift_purchase_id)
      gift = Orders::GiftPurchase.includes(order_item: { order: :event }).find_by(id: gift_purchase_id)
      return unless deliverable?(gift)

      revision = gift.delivery_revision
      return if gift.delivery_status == "sent"

      url = Links::BrandedUrl.gift(gift, token: gift.token)
      body = message_for(gift, url)
      sms_result = deliver_sms(gift, body, revision)
      email_result = deliver_email(gift, body, revision)
      sms_success = provider_success?(sms_result)
      email_success = email_result.nil? || provider_success?(email_result)
      status = if sms_success && email_success
        "sent"
      elsif sms_success || provider_success?(email_result)
        "partial"
      else
        "failed"
      end

      persist_delivery_result(gift.id, revision, status)
      raise delivery_error unless status == "sent"
    rescue ActiveRecord::RecordNotFound
      nil
    end

    private

    def deliverable?(gift)
      gift && gift.status.in?(%w[ready claimed]) && gift.expires_at > Time.current
    end

    def deliver_sms(gift, body, revision)
      adapter = registry.fetch(channel: "sms")
      return unavailable_result unless adapter&.respond_to?(:deliver_sms)

      adapter.deliver_sms(
        phone: gift.recipient_phone,
        body:,
        idempotency_key: "orders-gift-sms-#{gift.id}-r#{revision}"
      )
    end

    def deliver_email(gift, body, revision)
      email = gift.recipient_email.to_s.strip.presence
      return unless email

      adapter = registry.fetch(channel: "email")
      return unavailable_result unless adapter&.respond_to?(:deliver_email)

      adapter.deliver_email(
        to: email,
        subject: "A ticket gift for #{gift.order_item.order.event.title}",
        body:,
        idempotency_key: "orders-gift-email-#{gift.id}-r#{revision}"
      )
    end

    def persist_delivery_result(gift_id, revision, status)
      Orders::GiftPurchase.transaction do
        gift = Orders::GiftPurchase.lock.find_by(id: gift_id)
        return unless gift&.delivery_revision == revision && gift.status.in?(%w[ready claimed])
        return if gift.expires_at <= Time.current || gift.delivery_status == "sent"

        gift.update!(delivery_status: status, delivered_at: status == "sent" ? Time.current : nil)
      end
    end

    def registry
      Messaging::Providers::Registry.configure(
        Rails.application.config.x.messaging_provider_registry
      )
    end

    def provider_success?(result)
      result.is_a?(Messaging::Providers::DeliveryResult) && result.success?
    end

    def unavailable_result
      Messaging::Providers::DeliveryResult.failed(provider: "unavailable", failure_code: "adapter_unavailable")
    end

    def message_for(gift, url)
      note = gift.note.to_s.strip
      text = "You received a ticket gift for #{gift.order_item.order.event.title}: #{url}"
      note.present? ? "#{text}\n\nPersonal note: #{note}" : text
    end

    def delivery_error
      Core::Error.new(I18n.t("orders.gift_purchases.errors.gift_delivery_failed"))
    end
  end
end
