# frozen_string_literal: true

module Messaging
  # The single registry for notification categories, channels, safe fields,
  # recipient ownership, projections, locale keys, and versioned dedupe identities.
  module NotificationTypes
    class UnknownType < Core::Error; end

    module_function

    def fetch(key)
      definitions.fetch(key.to_s) do
        raise UnknownType, I18n.t("messaging.errors.unknown_notification_type", type: key)
      end
    end

    def keys
      definitions.keys
    end

    def definitions
      @definitions ||= build_definitions.freeze
    end

    def build_definitions
      {
        "payment_succeeded" => definition(
          key: "payment_succeeded",
          category: "transactional", mandatory: false,
          data_keys: %w[order_id payment_id event_id amount_minor currency],
          recipients: ->(source:, **) { source.buyer_user },
          dedupe: ->(source:, payload:, **) { "payment-succeeded:#{payload.fetch("payment_id", source.id)}:v1" },
          projector: ->(source:, payload:, **) {
            payload.slice("order_id", "payment_id", "event_id", "amount_minor", "currency").merge(
              "order_id" => source.id, "event_id" => source.event_id
            ).compact
          }
        ),
        "payment_failed" => definition(
          key: "payment_failed",
          category: "transactional", mandatory: false,
          data_keys: %w[order_id payment_id payment_event_id event_id failure_code],
          recipients: ->(source:, **) { source.order&.buyer_user },
          dedupe: ->(source:, payload:, **) { "payment-failed:#{payload.fetch("payment_event_id", source.id)}:v1" },
          projector: ->(source:, payload:, **) {
            payload.slice("payment_id", "payment_event_id", "order_id", "event_id", "failure_code").merge(
              "payment_id" => source.id, "order_id" => source.order_id, "event_id" => source.order.event_id
            ).compact
          }
        ),
        "ticket_issued" => definition(
          key: "ticket_issued",
          category: "credential", mandatory: true,
          data_keys: %w[ticket_id event_id product_id version event_title ticket_label],
          recipients: ->(source:, **) { source.owner_user },
          dedupe: ->(source:, payload:, **) { "ticket-issued:#{source.id}:v#{payload.fetch("version", source.credential_version)}" },
          projector: ->(source:, payload:, **) {
            payload.slice("ticket_id", "event_id", "product_id", "version", "event_title", "ticket_label").merge(
              "ticket_id" => source.id, "event_id" => source.event_id,
              "product_id" => source.event_product_id,
              "version" => payload["version"] || source.credential_version,
              "event_title" => source.event.title,
              "ticket_label" => source.event_product.name
            ).compact
          }
        ),
        "credential_replaced" => definition(
          key: "credential_replaced",
          category: "credential", mandatory: true,
          data_keys: %w[ticket_id event_id version],
          recipients: ->(source:, **) { source.owner_user },
          dedupe: ->(source:, payload:, **) { "credential-replaced:#{source.id}:v#{payload.fetch("version", source.credential_version)}" },
          projector: ->(source:, payload:, **) {
            payload.slice("ticket_id", "event_id", "version").merge(
              "ticket_id" => source.id, "event_id" => source.event_id,
              "version" => payload.fetch("version")
            ).compact
          }
        ),
        "refund_succeeded" => definition(
          key: "refund_succeeded",
          category: "transactional", mandatory: false,
          data_keys: %w[refund_id payment_id order_id event_id amount_minor currency],
          recipients: ->(source:, **) { source.payment&.order&.buyer_user },
          dedupe: ->(source:, payload:, **) { "refund-succeeded:#{payload.fetch("refund_id", source.id)}:v1" },
          projector: ->(source:, payload:, **) {
            payload.slice("refund_id", "payment_id", "order_id", "event_id", "amount_minor", "currency").merge(
              "refund_id" => source.id, "payment_id" => source.payment_id,
              "order_id" => source.payment.order_id, "event_id" => source.payment.order.event_id,
              "amount_minor" => source.amount_minor, "currency" => source.currency
            ).compact
          }
        ),
        "refund_failed" => definition(
          key: "refund_failed",
          category: "transactional", mandatory: false,
          data_keys: %w[refund_id payment_id order_id event_id amount_minor currency failure_code],
          recipients: ->(source:, **) { source.payment&.order&.buyer_user },
          dedupe: ->(source:, payload:, **) { "refund-failed:#{payload.fetch("refund_id", source.id)}:v1" },
          projector: ->(source:, payload:, **) {
            payload.slice("refund_id", "payment_id", "order_id", "event_id", "amount_minor", "currency", "failure_code").merge(
              "refund_id" => source.id, "payment_id" => source.payment_id,
              "order_id" => source.payment.order_id, "event_id" => source.payment.order.event_id,
              "amount_minor" => source.amount_minor, "currency" => source.currency
            ).compact
          }
        ),
        "transfer_received" => definition(
          key: "transfer_received",
          category: "transactional", mandatory: false,
          data_keys: %w[transfer_id ticket_id version],
          recipients: ->(source:, **) { source.to_user },
          dedupe: ->(source:, payload:, **) { "transfer-received:#{source.id}:v#{payload.fetch("version", source.new_version)}" },
          projector: ->(source:, payload:, **) {
            payload.slice("transfer_id", "ticket_id", "version").merge(
              "transfer_id" => source.id, "ticket_id" => source.ticket_id,
              "version" => source.new_version
            ).compact
          }
        ),
        "waitlist_offer_created" => definition(
          key: "waitlist_offer_created",
          category: "transactional", mandatory: false,
          data_keys: %w[registration_id event_id offer_expires_at],
          recipients: ->(source:, **) { source.user },
          dedupe: ->(source:, payload:, **) { waitlist_dedupe("created", source, payload) },
          projector: ->(source:, payload:, **) {
            payload.slice("registration_id", "event_id", "offer_expires_at").merge(
              "registration_id" => source.id, "event_id" => source.event_id,
              "offer_expires_at" => payload["offer_expires_at"] || source.offer_expires_at&.iso8601
            ).compact
          }
        ),
        "waitlist_offer_expired" => definition(
          key: "waitlist_offer_expired",
          category: "transactional", mandatory: false,
          data_keys: %w[registration_id event_id offer_expires_at],
          recipients: ->(source:, **) { source.user },
          dedupe: ->(source:, payload:, **) { waitlist_dedupe("expired", source, payload) },
          projector: ->(source:, payload:, **) {
            payload.slice("registration_id", "event_id", "offer_expires_at").merge(
              "registration_id" => source.id, "event_id" => source.event_id,
              "offer_expires_at" => payload["offer_expires_at"] || source.offer_expires_at&.iso8601
            ).compact
          }
        ),
        "registration_rejected" => definition(
          key: "registration_rejected",
          category: "transactional", mandatory: false,
          data_keys: %w[registration_id event_id reason_code],
          recipients: ->(source:, **) { source.user },
          dedupe: ->(source:, payload:, **) { "registration-rejected:#{payload.fetch("registration_id", source.id)}:v1" },
          projector: ->(source:, payload:, **) {
            payload.slice("registration_id", "event_id", "reason_code").merge(
              "registration_id" => source.id, "event_id" => source.event_id,
              "reason_code" => source.decision_reason
            ).compact
          }
        ),
        "consent_reminder" => definition(
          key: "consent_reminder",
          category: "legal", mandatory: true,
          data_keys: %w[registration_id requirement_id event_id required_at],
          recipients: ->(source:, **) { source.registration&.user },
          dedupe: ->(source:, payload:, **) { "consent-reminder:#{payload.fetch("requirement_id", source.id)}:v1" },
          projector: ->(source:, payload:, **) {
            payload.slice("registration_id", "requirement_id", "event_id", "required_at").merge(
              "registration_id" => source.registration_id, "requirement_id" => source.id,
              "event_id" => source.registration.event_id, "required_at" => source.required_at&.iso8601
            ).compact
          }
        ),
        "schedule_changed" => definition(
          key: "schedule_changed",
          category: "transactional", mandatory: false,
          data_keys: %w[event_id schedule_version event_date_ids],
          recipients: ->(**) { [] },
          dedupe: ->(source:, payload:, **) { "schedule-changed:#{source.id}:v#{payload.fetch("schedule_version", source.schedule_version)}" },
          projector: ->(source:, payload:, **) {
            payload.slice("event_id", "schedule_version", "event_date_ids").merge(
              "event_id" => source.id,
              "schedule_version" => payload.fetch("schedule_version", source.schedule_version)
            ).compact
          }
        )
      }
    end

    def definition(key:, category:, mandatory:, data_keys:, recipients:, dedupe:, projector: nil)
      NotificationTypeDefinition.new(
        key:,
        category:, mandatory:, channels: NotificationDelivery::CHANNELS,
        data_keys:, locale_scope: "messaging.notifications", recipient_resolver: recipients,
        dedupe_resolver: dedupe, projector:
      )
    end

    def waitlist_dedupe(kind, source, payload)
      offer_identity = payload.fetch("offer_expires_at", source.offer_expires_at).to_s
      "waitlist-offer-#{kind}:#{source.id}:#{source.event_id}:#{offer_identity}:v1"
    end
  end
end
