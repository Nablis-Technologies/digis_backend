# frozen_string_literal: true

module Ticketing
  module OutboxHandlers
    # Hands a committed package-issued event to the future Messaging adapter.
    # Only durable IDs and the outbox idempotency key cross this seam; the
    # handler never loads or forwards QR, PNR, consent, or financial data.
    class PackageIssued < Core::BaseService
      def initialize(event:, sender: nil)
        @event = event
        @sender = sender
      end

      def call
        details = {
          ticket_id: @event.payload.fetch("ticket_id"),
          version: @event.payload.fetch("version"),
          idempotency_key: @event.idempotency_key
        }
        sender.call(**details) if sender
        enqueue_guest_delivery(details.fetch(:ticket_id))
        success(details)
      rescue KeyError
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_issuance.errors.invalid_package_issued_event"),
            code: "invalid_package_issued_event",
            status: :unprocessable_entity
          )
        )
      end

      private

      attr_reader :event

      def sender
        @sender || Rails.application.config.x.credential_delivery_sender
      end

      def enqueue_guest_delivery(ticket_id)
        ticket = Ticketing::Ticket.includes(:owner_user).find(ticket_id)
        return unless ticket.owner_user.verified_at.blank? && ticket.owner_user.password_digest.blank?

        Ticketing::GuestTicketDeliveryJob.perform_later(ticket.id)
      rescue ActiveRecord::RecordNotFound
        nil
      end
    end
  end
end
