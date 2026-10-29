# frozen_string_literal: true

require "digest"
require "json"

module Orders
  # Verifies and durably records a provider callback before any order state is
  # changed. The inbox row and its processing outbox event share one
  # transaction, so an acknowledged webhook always has a resumable job.
  class RecordPaymentEvent < Core::BaseService
    def initialize(provider:, provider_event_id:, event_type:, payload:, raw_payload: nil,
      signature:, headers: {}, occurred_at: nil)
      @provider = provider.to_s.strip.downcase
      @provider_event_id = provider_event_id.to_s.strip
      @event_type = event_type.to_s.strip.downcase
      @payload = payload.to_h.deep_stringify_keys
      @raw_payload = raw_payload.presence || JSON.generate(@payload.sort.to_h)
      @signature = signature.to_s
      @headers = headers.to_h.stringify_keys
      @occurred_at = parse_time(occurred_at || @payload["occurred_at"])
    rescue ArgumentError, TypeError
      @initialization_error = true
    end

    def call
      return failure(webhook_error(:invalid_webhook_payload, code: "invalid_webhook_payload")) if @initialization_error
      return failure(webhook_error(:invalid_webhook_provider, code: "invalid_webhook_provider")) if provider.blank?
      return failure(webhook_error(:invalid_webhook_payload, code: "invalid_webhook_payload")) if provider_event_id.blank? || event_type.blank?

      adapter = Payments::Providers::Registry.fetch(provider)
      valid_signature = adapter.verify_webhook(
        payload: raw_payload,
        parsed_payload: payload,
        signature:,
        headers:,
        provider_event_id:,
        event_type:
      )
      return failure(webhook_error(:invalid_webhook_signature, code: "invalid_webhook_signature", status: :unauthorized)) unless valid_signature

      digest = Digest::SHA256.hexdigest(raw_payload)
      created = false
      event = ActiveRecord::Base.transaction do
        record = Orders::PaymentEvent.create_or_find_by!(provider:, provider_event_id:) do |row|
          created = true
          row.assign_attributes(
            event_type:,
            status: "received",
            payload:,
            payload_digest: digest,
            occurred_at:,
            received_at: Time.current
          )
        end
        publish_processing!(record) if created
        record
      end
      success(event)
    rescue KeyError
      failure(webhook_error(:invalid_webhook_provider, code: "invalid_webhook_provider"))
    rescue ActiveRecord::RecordInvalid => error
      failure(webhook_error(:invalid_webhook_payload, code: "invalid_webhook_payload", errors: error.record.errors.to_hash))
    end

    private

    attr_reader :provider, :provider_event_id, :event_type, :payload, :raw_payload, :signature, :headers, :occurred_at

    def publish_processing!(event)
      result = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.payment_event.received",
        aggregate: event,
        payload: {
          payment_event_id: event.id,
          provider: event.provider,
          provider_event_id: event.provider_event_id
        },
        idempotency_key: "orders-payment-event-received-#{event.id}"
      )
      raise result.error if result.failure?
    end

    def parse_time(value)
      return if value.blank?

      Time.iso8601(value.to_s)
    end

    def webhook_error(key, code:, status: :unprocessable_entity, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.payments.webhooks.errors.#{key}"),
        code:, status:, errors:
      )
    end
  end
end
