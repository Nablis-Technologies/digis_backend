# frozen_string_literal: true

module Orders
  # Creates the durable full-refund obligation for a succeeded payment that
  # Orders did not accept. The payment and its prior refunds are locked before
  # the deterministic payment-derived key is checked, so concurrent provider
  # callbacks cannot create two reversals or mutate fulfillment state.
  class CreatePaymentReversal < Core::BaseService
    REASONS = Orders::Refund::PAYMENT_REVERSAL_REASONS

    def initialize(payment:, reason_code:)
      @payment = payment
      @reason_code = reason_code.to_s.strip.downcase
    end

    def call
      return failure(reversal_error(:invalid_reversal_reason, code: "invalid_reversal_reason")) unless REASONS.include?(reason_code)

      refund = ActiveRecord::Base.transaction do
        payment = Orders::Payment.lock.find(@payment.id)
        prior_refunds = Orders::Refund.where(payment_id: payment.id).order(:id).lock.to_a
        key = reversal_key(payment)
        existing = prior_refunds.find { |row| row.idempotency_key == key }
        if existing
          unless existing.type == "payment_reversal"
            raise ReversalAbort, reversal_error(:reversal_conflict, code: "reversal_conflict")
          end
          next existing
        end

        unless payment.status == "succeeded" && payment.accepted_at.nil?
          raise ReversalAbort, reversal_error(:payment_not_reversible, code: "payment_not_reversible")
        end

        created = Orders::Refund.create!(
          payment:,
          type: "payment_reversal",
          idempotency_key: key,
          amount_minor: payment.amount_minor,
          currency: payment.currency,
          status: "created",
          reason_code:,
          reason: I18n.t("orders.payments.reversals.reasons.#{reason_code}")
        )
        publish_reversal!(created, payment)
        created
      end

      success(refund)
    rescue ReversalAbort => error
      failure(error.business_error)
    rescue ActiveRecord::RecordInvalid => error
      failure(
        reversal_error(
          :reversal_failed,
          code: "reversal_failed",
          errors: error.record.errors.to_hash
        )
      )
    rescue ActiveRecord::RecordNotUnique
      failure(reversal_error(:reversal_conflict, code: "reversal_conflict"))
    end

    private

    attr_reader :payment, :reason_code

    def reversal_key(locked_payment)
      "payment-reversal:#{locked_payment.id}"
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

    class ReversalAbort < Core::Error
      attr_reader :business_error

      def initialize(error)
        @business_error = error
        super(error.message)
      end
    end
  end
end
