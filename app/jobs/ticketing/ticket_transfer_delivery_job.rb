# frozen_string_literal: true

module Ticketing
  # Delivers one pending transfer invitation through configured SMS/email
  # adapters. The queue carries only the transfer ID; the encrypted token is
  # decrypted inside the job and provider retries reuse stable idempotency keys.
  class TicketTransferDeliveryJob < ApplicationJob
    queue_as :notifications
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(transfer_id)
      transfer = Ticketing::TicketTransfer.includes(
        :to_user,
        ticket: :event
      ).find_by(id: transfer_id)
      return unless transfer&.status == "pending"

      token = transfer.token
      raise Core::Error, I18n.t("ticketing.package_workflow.errors.transfer_delivery_failed") if token.blank?

      url = Links::BrandedUrl.transfer(transfer, token)
      deliver_sms(transfer, url)
      deliver_email(transfer, url)
    end

    private

    def deliver_sms(transfer, url)
      adapter = registry.fetch(channel: "sms")
      return unless adapter&.respond_to?(:deliver_sms)

      result = adapter.deliver_sms(
        phone: transfer.to_user.phone,
        body: message_for(transfer, url),
        idempotency_key: "ticketing-transfer-sms-#{transfer.id}"
      )
      raise delivery_error unless result.is_a?(Messaging::Providers::DeliveryResult) && result.success?
    end

    def deliver_email(transfer, url)
      email = transfer.to_user.email.to_s.strip.presence
      adapter = registry.fetch(channel: "email")
      return unless email && adapter&.respond_to?(:deliver_email)

      result = adapter.deliver_email(
        to: email,
        subject: "Ticket transfer for #{transfer.ticket.event.title}",
        body: message_for(transfer, url),
        idempotency_key: "ticketing-transfer-email-#{transfer.id}"
      )
      raise delivery_error unless result.is_a?(Messaging::Providers::DeliveryResult) && result.success?
    end

    def registry
      Messaging::Providers::Registry.configure(
        Rails.application.config.x.messaging_provider_registry
      )
    end

    def message_for(transfer, url)
      "You received a ticket for #{transfer.ticket.event.title}: #{url}"
    end

    def delivery_error
      Core::Error.new(I18n.t("ticketing.package_workflow.errors.transfer_delivery_failed"))
    end
  end
end
