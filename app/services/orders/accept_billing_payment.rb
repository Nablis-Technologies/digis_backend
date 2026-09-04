# frozen_string_literal: true

module Orders
  # Accepts a billing purchase payment and emits the durable Messaging grant
  # boundary. No event order, ticket fulfillment, or Finance ledger is touched.
  class AcceptBillingPayment < Core::BaseService
    def initialize(payment:, payment_event: nil, at: Time.current)
      @payment = payment
      @payment_event = payment_event
      @now = at.to_time.utc
    end

    def call
      ActiveRecord::Base.transaction do
        payment = Orders::Payment.includes(:billing_purchase).lock.find(@payment.id)
        purchase = Orders::BillingPurchase.lock.find(payment.billing_purchase_id)
        return success(payment) if payment.accepted?

        payment.update!(status: "succeeded", succeeded_at: payment.succeeded_at || now)
        if purchase.closed? || purchase.paid? || purchase.expires_at <= now
          # Closed/expired and duplicate billing payments are provider evidence
          # that must be reversed; they never become a second credit grant.
          reason_code = purchase.paid? ? "duplicate_payment" : "late_payment"
          reversal = Orders::CreatePaymentReversal.call(payment:, reason_code:)
          raise reversal.error if reversal.failure?

          unless purchase.paid?
            purchase.update!(status: "reversed") unless purchase.reversed?
            publish!(payment, purchase, "orders.billing_payment.reversed")
          end
          return success(payment.reload)
        end

        payment.update!(accepted_at: now)
        purchase.update!(status: "paid", provider_reference: payment.provider_reference)
        publish!(payment, purchase, "orders.billing_payment.accepted")
        success(payment.reload)
      end
    rescue ActiveRecord::RecordNotFound
      failure(error(:payment_attempt_unavailable, status: :conflict))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:provider_result_invalid, errors: exception.record.errors.to_hash))
    rescue Core::Error => exception
      failure(exception)
    end

    private

    attr_reader :payment, :payment_event, :now

    def publish!(payment, purchase, event_type)
      result = Core::Outbox::Publish.call(
        topic: "orders", event_type:, aggregate: payment,
        payload: {
          payment_id: payment.id,
          billing_purchase_id: purchase.id,
          source_type: purchase.source_type,
          source_id: purchase.source_id,
          amount_minor: purchase.amount_minor,
          currency: purchase.currency
        },
        idempotency_key: "#{event_type}-#{payment.id}"
      )
      raise result.error if result.failure?
    end

    def error(key, status: :unprocessable_entity, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.payments.errors.#{key}"), code: key.to_s, status:, errors:
      )
    end
  end
end
