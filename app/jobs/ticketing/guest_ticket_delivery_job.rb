# frozen_string_literal: true

module Ticketing
  # Sends the guest's convenience link after issuance. This job is deliberately
  # outside payment/fulfillment transactions; SMS failure only retries this
  # notification and never changes ticket or payment state.
  class GuestTicketDeliveryJob < ApplicationJob
    queue_as :notifications
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(ticket_id)
      ticket = Ticketing::Ticket.includes(
        :event,
        :owner_user,
        event_product: { product_accesses: { event_date: :venue } }
      ).find(ticket_id)
      return unless guest_owner?(ticket)

      adapter = Messaging::Providers::Registry.configure(
        Rails.application.config.x.messaging_provider_registry
      ).fetch(channel: "sms")
      return unless adapter&.respond_to?(:deliver_sms)

      result = adapter.deliver_sms(
        phone: ticket.owner_user.phone,
        body: message_for(ticket),
        idempotency_key: "ticketing-guest-ticket-sms-#{ticket.id}-v#{ticket.credential_version}"
      )
      if result.is_a?(Messaging::Providers::DeliveryResult) && result.success?
        Core::Telemetry.instrument(
          "ticketing.guest_checkout.sms_delivery",
          aggregate_id: ticket.id,
          event_id: ticket.event_id,
          provider: result.provider,
          outcome: result.status
        ) { }
        return
      end

      raise Core::Error, I18n.t("ticketing.guest_ticket.errors.sms_delivery_failed")
    rescue ActiveRecord::RecordNotFound, ArgumentError
      nil
    end

    private

    def guest_owner?(ticket)
      ticket.owner_user.verified_at.blank? && ticket.owner_user.password_digest.blank?
    end

    def message_for(ticket)
      "Your ticket for #{ticket.event.title} is ready: #{Links::BrandedUrl.ticket(ticket)}"
    end
  end
end
