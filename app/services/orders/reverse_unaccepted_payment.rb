# frozen_string_literal: true

module Orders
  # Records the full provider-refund obligation for a succeeded payment that
  # lost acceptance. The unique payment-derived key prevents concurrent
  # callbacks from creating or submitting two reversal obligations.
  class ReverseUnacceptedPayment < Core::BaseService
    REASONS = Orders::Refund::PAYMENT_REVERSAL_REASONS

    def initialize(payment:, reason_code:)
      @payment = payment
      @reason_code = reason_code.to_s.strip.downcase
    end

    def call
      return failure(reversal_error(:invalid_reversal_reason, code: "invalid_reversal_reason")) unless REASONS.include?(reason_code)

      refund = ActiveRecord::Base.transaction do
        payment = Orders::Payment.lock.find(@payment.id)
        unless payment.status == "succeeded" && payment.accepted_at.nil?
          return failure(reversal_error(:payment_not_reversible, code: "payment_not_reversible"))
        end

        record = Orders::Refund.create_or_find_by!(idempotency_key: reversal_key(payment)) do |row|
          row.assign_attributes(
            payment:,
            type: "payment_reversal",
            amount_minor: payment.amount_minor,
            currency: payment.currency,
            status: "created",
            reason_code:,
            reason: I18n.t("orders.payments.reversals.reasons.#{reason_code}")
          )
        end
        publish_reversal!(record, payment)
        record
      end
      success(refund)
    rescue ActiveRecord::RecordInvalid => error
      failure(reversal_error(:reversal_failed, code: "reversal_failed", errors: error.record.errors.to_hash))
    end

    private

    attr_reader :payment, :reason_code

    def reversal_key(locked_payment)
      "orders-payment-reversal-#{locked_payment.id}"
    end

    def publish_reversal!(refund, locked_payment)
      result = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.payment_reversal.created",
        aggregate: locked_payment,
        payload: {
          refund_id: refund.id,
          payment_id: locked_payment.id,
          order_id: locked_payment.order_id,
          reason_code: refund.reason_code
        },
        idempotency_key: "orders-payment-reversal-created-#{locked_payment.id}"
      )
      raise result.error if result.failure?
    end

    def reversal_error(key, code:, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.payments.reversals.errors.#{key}"),
        code:, status: :conflict, errors:
      )
    end
  end
end
