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
          acceptance = if payment.billing_payment?
            Orders::AcceptBillingPayment.call(payment:, payment_event: event)
          else
            Orders::AcceptPayment.call(payment:, payment_event: event)
          end
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
      return Orders::Payment.find(locked_event.payment_id) if locked_event.payment_id

      # Chapa V2 carries Digis's bounded merchant reference separately from
      # the provider's own chapa_reference.
      references = locked_event.payload.values_at(
        "provider_reference", "chapa_reference", "merchant_reference", "tx_ref", "reference"
      ).filter_map(&:presence)
      references.each do |reference|
        payment = Orders::Payment.find_by(provider: locked_event.provider, provider_merchant_reference: reference) ||
          Orders::Payment.find_by(provider: locked_event.provider, provider_reference: reference) ||
          Orders::Payment.find_by(provider: locked_event.provider, idempotency_key: reference)
        return payment if payment
      end
      nil
    end

    def success_event?(locked_event)
      status = locked_event.payload["status"].to_s.downcase
      SUCCESS_EVENT_STATUSES.include?(status) || locked_event.event_type.match?(/success|succeed|paid|completed/)
    end

    def apply_non_success_state!(payment, locked_event)
      status = locked_event.payload["status"].to_s.downcase
      target = if payment.billing_payment? && %w[reversed refunded].include?(status)
        "reversed"
      elsif FAILURE_EVENT_STATUSES.include?(status)
        "failed"
      elsif CANCELLED_EVENT_STATUSES.include?(status)
        "cancelled"
      end
      return unless target
      if target == "reversed" && payment.billing_payment?
        if payment.accepted_at.present?
          payment.update!(failure_code: locked_event.payload["failure_code"].to_s.presence)
          payment.billing_purchase.update!(status: "reversed")
          publish_failure!(payment, locked_event, event_type: "orders.billing_payment.reversed")
        elsif payment.succeeded_at.present?
          # An unaccepted duplicate is already provider evidence; do not
          # downgrade the valid purchase or revoke credits for another attempt.
          payment.update!(failure_code: locked_event.payload["failure_code"].to_s.presence)
        else
          payment.update!(status: "reversed")
          if billing_purchase_should_close?(payment, payment.billing_purchase)
            payment.billing_purchase.update!(status: "reversed")
            publish_failure!(payment, locked_event, event_type: "orders.billing_payment.reversed")
          end
        end
        return
      end
      return unless payment.accepted_at.nil? && payment.status.in?(%w[created processing])

      payment.update!(status: target, failure_code: locked_event.payload["failure_code"].to_s.presence)
      if target == "failed"
        billing_purchase = payment.billing_purchase
        billing_purchase.update!(status: "failed") if billing_purchase_should_close?(payment, billing_purchase)
        publish_failure!(
          payment, locked_event,
          event_type: payment.billing_payment? ? "orders.billing_payment.failed" : "orders.payment.failed"
        )
      elsif target == "cancelled"
        billing_purchase = payment.billing_purchase
        billing_purchase.update!(status: "cancelled") if billing_purchase_should_close?(payment, billing_purchase)
      end
    end

    def billing_purchase_should_close?(payment, purchase)
      # Only the current, still-open attempt may close a billing purchase. A
      # superseded or concurrently active attempt keeps the purchase retryable.
      return false unless purchase && purchase.status.in?(%w[created pending_payment])
      return false if payment.superseded_at.present?

      !purchase.payments.where(status: %w[created processing succeeded]).where.not(id: payment.id).exists?
    end

    # The payment failure event is emitted in the same transaction as the
    # authoritative status transition, so notification projection cannot race
    # a still-processing payment or publish twice for one provider event.
    def publish_failure!(payment, locked_event, event_type: "orders.payment.failed")
      result = Core::Outbox::Publish.call(
        topic: "orders",
        event_type:,
        aggregate: payment,
        payload: {
          payment_id: payment.id,
          payment_event_id: locked_event.id,
          order_id: payment.order_id,
          event_id: payment.order&.event_id,
          billing_purchase_id: payment.billing_purchase_id,
          source_type: payment.billing_purchase&.source_type,
          source_id: payment.billing_purchase&.source_id,
          failure_code: payment.failure_code
        }.compact,
        idempotency_key: "orders-payment-failed-#{locked_event.id}"
      )
      raise result.error if result.failure?
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
