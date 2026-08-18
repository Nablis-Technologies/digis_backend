# frozen_string_literal: true

module Ticketing
  module OutboxHandlers
    # Hands a committed generation replacement to the credential-delivery
    # adapter. Only the ticket/version identifiers cross the outbox boundary;
    # QR, PNR, consent, and financial data stay behind the service boundary.
    class CredentialGenerationReplaced < Core::BaseService
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
        success(details)
      rescue KeyError
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_issuance.errors.invalid_generation_replaced_event"),
            code: "invalid_generation_replaced_event",
            status: :unprocessable_entity
          )
        )
      end

      private

      attr_reader :event

      def sender
        @sender || Rails.application.config.x.credential_delivery_sender
      end
    end
  end
end
