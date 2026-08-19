# frozen_string_literal: true

require "digest"
require "json"

module Orders
  # Verifies a provider redirect before creating the same durable payment-event
  # inbox used by signed webhooks. Callback query parameters are evidence for
  # lookup only; the provider's verification response determines the event.
  class RecordPaymentCallback < Core::BaseService
    def initialize(provider:, transaction_reference:, provider_reference:, callback_status:)
      @provider = provider.to_s.strip.downcase
      @transaction_reference = transaction_reference.to_s.strip
      @provider_reference = provider_reference.to_s.strip.presence
      @callback_status = callback_status.to_s.strip.presence
    end

    def call
      return failure(callback_error(:invalid_callback, code: "invalid_callback", status: :bad_request)) unless valid_request?

      payment = find_payment
      return failure(callback_error(:payment_not_found, code: "payment_not_found", status: :not_found)) unless payment

      verified = verify_payment
      persist_event(payment, verified)
    rescue KeyError, ArgumentError
      failure(callback_error(:provider_unavailable, code: "provider_unavailable", status: :service_unavailable))
    end

    private

    attr_reader :provider, :transaction_reference, :provider_reference, :callback_status

    def valid_request?
      provider.present? && transaction_reference.present?
    end

    def find_payment
      payment = Orders::Payment.find_by(provider:, idempotency_key: transaction_reference)
      return payment if payment
      return unless provider_reference.present?

      Orders::Payment.find_by(provider:, provider_reference: provider_reference)
    end

    def verify_payment
      adapter = Payments::Providers::Registry.fetch(provider)
      result = adapter.verify(
        provider_reference: transaction_reference,
        idempotency_key: transaction_reference
      )
      result.is_a?(Payments::Providers::Result) ? result : Payments::Providers::Result.from_provider_response(result)
    end

    def persist_event(payment, verified)
      event_type, status = event_projection(verified)
      normalized_provider_reference = verified.provider_reference.presence || provider_reference
      payload = {
        "status" => status,
        "raw_status" => verified.raw_status,
        "tx_ref" => transaction_reference,
        "provider_reference" => normalized_provider_reference,
        "failure_code" => verified.failure_code,
        "callback_status" => callback_status
      }.compact
      provider_event_id = Digest::SHA256.hexdigest(
        [ provider, transaction_reference, event_type, normalized_provider_reference ].join(":"
        )
      )
      raw_payload = JSON.generate(payload.sort.to_h)
      created = false

      event = ActiveRecord::Base.transaction do
        record = Orders::PaymentEvent.create_or_find_by!(provider:, provider_event_id:) do |row|
          created = true
          row.assign_attributes(
            payment:,
            event_type:,
            status: "received",
            payload:,
            payload_digest: Digest::SHA256.hexdigest(raw_payload),
            occurred_at: Time.current,
            received_at: Time.current
          )
        end
        publish_processing!(record) if created
        record
      end
      success(event)
    rescue ActiveRecord::RecordInvalid => error
      failure(callback_error(
        :invalid_callback, code: "invalid_callback", status: :unprocessable_entity,
        errors: error.record.errors.to_hash
      ))
    end

    def event_projection(verified)
      case verified.status
      when "success"
        [ "payment.succeeded", "success" ]
      when "failure"
        [ "payment.failed", "failed" ]
      when "cancelled"
        [ "payment.cancelled", "cancelled" ]
      else
        [ "payment.pending", "pending" ]
      end
    end

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

    def callback_error(key, code:, status:, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.payments.callbacks.errors.#{key}"), code:, status:, errors:
      )
    end
  end
end
