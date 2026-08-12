# frozen_string_literal: true

module Orders
  # Processes one inbox row under its lock, then delegates the payment/order
  # lock set to AcceptPayment. A failed worker leaves a scrubbed error and a
  # retryable status; a processed or ignored row is a replay no-op.
  class ProcessPaymentEvent < Core::BaseService
    SUCCESS_EVENT_STATUSES = %w[success succeeded paid completed].freeze
    FAILURE_EVENT_STATUSES = %w[failure failed declined error].freeze
    CANCELLED_EVENT_STATUSES = %w[cancelled canceled].freeze

    def initialize(event: nil, event_id: nil)
      @event = event
      @event_id = event_id || event&.id
    end

    def call
      result = ActiveRecord::Base.transaction do
        event = Orders::PaymentEvent.lock.find(@event_id)
        return success(event) if event.terminal?

        event.update!(status: "processing", attempts_count: event.attempts_count + 1, last_error: nil)
        payment = locate_payment(event)
        return finish_ignored!(event) unless payment
        event.update!(payment_id: payment.id) if event.payment_id.nil?

        if success_event?(event)
          acceptance = Orders::AcceptPayment.call(payment:, payment_event: event)
          return fail_event!(event, acceptance.error) if acceptance.failure?
        else
          apply_non_success_state!(payment, event)
        end

        finish_processed!(event)
      end
      result
    rescue ActiveRecord::RecordNotFound
      failure(processing_error(:payment_event_not_found, code: "payment_event_not_found"))
    rescue ActiveRecord::RecordInvalid => error
      failure(processing_error(:payment_event_processing_failed, code: "payment_event_processing_failed", errors: error.record.errors.to_hash))
    end

    private

    attr_reader :event, :event_id

    def locate_payment(locked_event)
      return Orders::Payment.lock.find(locked_event.payment_id) if locked_event.payment_id

      reference = locked_event.payload.values_at("provider_reference", "tx_ref", "reference").compact.find(&:present?)
      return unless reference

      Orders::Payment.lock.find_by(provider: locked_event.provider, provider_reference: reference)
    end

    def success_event?(locked_event)
      status = locked_event.payload["status"].to_s.downcase
      SUCCESS_EVENT_STATUSES.include?(status) || locked_event.event_type.match?(/success|succeed|paid|completed/)
    end

    def apply_non_success_state!(payment, locked_event)
      status = locked_event.payload["status"].to_s.downcase
      target = if FAILURE_EVENT_STATUSES.include?(status)
        "failed"
      elsif CANCELLED_EVENT_STATUSES.include?(status)
        "cancelled"
      end
      return unless target && payment.accepted_at.nil? && payment.status.in?(%w[created processing])

      payment.update!(status: target, failure_code: locked_event.payload["failure_code"].to_s.presence)
    end

    def finish_ignored!(locked_event)
      locked_event.update!(status: "ignored", processed_at: Time.current)
      success(locked_event)
    end

    def finish_processed!(locked_event)
      locked_event.update!(status: "processed", processed_at: Time.current, last_error: nil)
      success(locked_event)
    end

    def fail_event!(locked_event, error)
      locked_event.update!(status: "failed", last_error: error.code.to_s.first(120))
      failure(error)
    end

    def processing_error(key, code:, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.payments.webhooks.errors.#{key}"),
        code:, status: :unprocessable_entity, errors:
      )
    end
  end
end
