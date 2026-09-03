# frozen_string_literal: true

module Messaging
  module OutboxHandlers
    # Projects committed domain events into recipient-owned notifications.
    # Definitions own source-aware projections; the projection service applies
    # the final allowlist so raw outbox payloads never become inbox data.
    class PublishTransactionalNotification < Core::BaseService
      EVENT_TYPES = {
        "orders.payment.fulfilled" => "payment_succeeded",
        "orders.payment.failed" => "payment_failed",
        "orders.refund.succeeded" => "refund_succeeded",
        "orders.refund.failed" => "refund_failed",
        "ticketing.package_issued" => "ticket_issued",
        "ticketing.credential_generation_replaced" => "credential_replaced",
        "ticketing.ticket_transfer.accepted" => "transfer_received",
        "ticketing.registration.waitlist_offer_created" => "waitlist_offer_created",
        "ticketing.registration.waitlist_offer_expired" => "waitlist_offer_expired",
        "ticketing.registration.rejected" => "registration_rejected",
        "ticketing.registration_consent.reminder_due" => "consent_reminder",
        "events.schedule_changed" => "schedule_changed"
      }.freeze

      def initialize(event:)
        @event = event
      end

      def call
        type = EVENT_TYPES[@event.event_type]
        return failure(error(:unsupported_event, :unprocessable_entity)) unless type
        return enqueue_schedule_fanout if type == "schedule_changed"

        source = source_for(@event.event_type)
        definition = NotificationTypes.fetch(type)
        recipient = definition.recipient_for(source:, payload: @event.payload)
        return failure(error(:recipient_unavailable, :unprocessable_entity)) unless recipient
        projection = definition.project(source:, payload: @event.payload)

        published = PublishNotification.call(
          type:, recipient:, source:, data: projection,
          dedupe_key: definition.dedupe_key_for(
            source:, recipient:, payload: projection
          )
        )
        return failure(published.error) if published.failure?

        success(published.value)
      rescue ActiveRecord::RecordNotFound, KeyError
        failure(error(:recipient_unavailable, :unprocessable_entity))
      rescue NotificationTypes::UnknownType => exception
        failure(exception)
      end

      private

      def enqueue_schedule_fanout
        Messaging::FanoutNotificationJob.perform_later(@event.id)
        success(@event)
      end

      def source_for(event_type)
        # Dispatch always supplies a persisted outbox row; resolve the
        # authoritative aggregate by ID so tests and production share one
        # privacy/strict-loading path.
        case event_type
        when "orders.payment.fulfilled"
          Orders::Order.includes(:buyer_user, :event).find(@event.payload.fetch("order_id"))
        when "orders.payment.failed"
          Orders::Payment.includes(order: [ :buyer_user, :event ]).find(@event.payload.fetch("payment_id"))
        when /^orders\.refund\./
          Orders::Refund.includes(payment: { order: [ :buyer_user, :event ] }).find(@event.payload.fetch("refund_id"))
        when "ticketing.package_issued", "ticketing.credential_generation_replaced"
          Ticketing::Ticket.includes(:owner_user, :event, :event_product).find(@event.payload.fetch("ticket_id"))
        when "ticketing.ticket_transfer.accepted"
          Ticketing::TicketTransfer.includes(:to_user, :ticket).find(@event.payload.fetch("transfer_id"))
        when /^ticketing\.registration\./, "ticketing.registration.rejected"
          Ticketing::Registration.includes(:user, :event).find(@event.payload.fetch("registration_id"))
        when "ticketing.registration_consent.reminder_due"
          Ticketing::RegistrationConsentRequirement.includes(registration: [ :user, :event ]).find(
            @event.payload.fetch("requirement_id")
          )
        else
          raise KeyError, event_type
        end
      end

      def error(key, status)
        Core::BusinessError.new(I18n.t("messaging.errors.#{key}"), code: key, status:)
      end
    end
  end
end
