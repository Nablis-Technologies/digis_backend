# frozen_string_literal: true

module Orders
  # Verifies a refund whose provider outcome is ambiguous. It never invokes
  # the refund operation again: the provider idempotency key and verification
  # endpoint are the recovery boundary after a worker crash or timeout.
  class ReconcileRefund < Core::BaseService
    def initialize(refund:, now: Time.current)
      @refund = refund
      @now = now.to_time.utc
    end

    def call
      snapshot = load_snapshot
      return success(snapshot[:refund]) if snapshot[:skip]

      adapter = Payments::Providers::Registry.fetch(snapshot[:provider])
      provider_result = adapter.verify_refund(
        payment_id: snapshot[:payment_id],
        provider_reference: snapshot[:provider_reference],
        amount_minor: snapshot[:amount_minor],
        currency: snapshot[:currency],
        idempotency_key: snapshot[:idempotency_key]
      )
      applied = Orders::ApplyRefundResult.call(refund: snapshot[:refund], result: provider_result, now:)
      return failure(applied.error) if applied.failure?

      success(applied.value)
    rescue KeyError
      failure(refund_error(:provider_unavailable, code: "provider_unavailable", status: :service_unavailable))
    rescue NotImplementedError
      failure(refund_error(:refund_verification_unsupported, code: "refund_verification_unsupported"))
    rescue ActiveRecord::RecordNotFound
      failure(refund_error(:refund_not_found, code: "refund_not_found"))
    end

    private

    attr_reader :refund, :now

    def load_snapshot
      ActiveRecord::Base.transaction do
        locked_refund = Orders::Refund.lock.find(refund.id)
        next { skip: true, refund: locked_refund } unless locked_refund.status == "processing"

        payment = Orders::Payment.find(locked_refund.payment_id)
        {
          refund: locked_refund,
          provider: payment.provider,
          payment_id: payment.id,
          provider_reference: locked_refund.provider_reference.presence || payment.provider_reference,
          amount_minor: locked_refund.amount_minor,
          currency: locked_refund.currency,
          idempotency_key: locked_refund.idempotency_key
        }
      end
    end

    def refund_error(key, code:, status: :conflict)
      Core::BusinessError.new(I18n.t("orders.refunds.errors.#{key}"), code:, status:)
    end
  end
end
