# frozen_string_literal: true

module Orders
  # Performs the final provider check outside database locks, then reacquires
  # order → payment → reservation state before accepting or releasing it. A
  # released checkout is never rebuilt when a late success appears later; the
  # normal payment acceptance path creates the idempotent reversal instead.
  class ExpireSettlementGrace < Core::BaseService
    def initialize(payment: nil, payment_id: nil, now: Time.current)
      @payment_id = payment_id || payment&.id
      @now = now.to_time.utc
    end

    def call
      candidate = Orders::Payment.find(@payment_id)
      return failure(grace_error(:event_payment_required, code: "event_payment_required")) if candidate.billing_payment?
      return success(candidate) unless due?(candidate)

      verification = verify_provider(candidate)
      ActiveRecord::Base.transaction do
        order = Orders::Order.lock.find(candidate.order_id)
        payment = Orders::Payment.lock.find_by!(id: candidate.id, order_id: order.id)
        return success(payment) unless payment.current? && due?(payment)

        apply_provider_result!(payment, verification)
        if verification.success?
          acceptance = Orders::AcceptPayment.call(payment:, at: now)
          raise GraceFailure, acceptance.error if acceptance.failure?
          return success(payment.reload)
        end

        release = Orders::ReleaseCheckout.call(order:, at: now)
        raise GraceFailure, release.error if release.failure?
        success(payment.reload)
      end
    rescue ActiveRecord::RecordNotFound
      failure(grace_error(:settlement_grace_not_found, code: "settlement_grace_not_found"))
    rescue GraceFailure => error
      failure(grace_error(:settlement_grace_failed, code: "settlement_grace_failed", errors: error.errors))
    end

    private

    attr_reader :payment_id, :now

    def due?(payment)
      payment.current? && payment.settlement_grace_expires_at <= now
    end

    def verify_provider(payment)
      adapter = Payments::Providers::Registry.fetch(payment.provider)
      response = adapter.verify(
        payment_id: payment.id,
        order_id: payment.order_id,
        provider_reference: payment.provider_reference,
        amount_minor: payment.amount_minor,
        currency: payment.currency,
        idempotency_key: "orders-payment-verification-#{payment.id}"
      )
      response.is_a?(Payments::Providers::Result) ? response : Payments::Providers::Result.from_provider_response(response)
    rescue StandardError => error
      Rails.logger.warn("payment settlement verification was unresolved: #{error.class}")
      Payments::Providers::Result.unknown(raw_status: "verification_unavailable")
    end

    def apply_provider_result!(payment, result)
      attributes = {
        status: status_for(result),
        provider_reference: result.provider_reference || payment.provider_reference,
        failure_code: result.failure_code,
        provider_fee_minor: result.provider_fee_minor,
        provider_fee_currency: result.provider_fee_currency,
        raw_status: result.raw_status.presence || result.status
      }
      attributes[:succeeded_at] = payment.succeeded_at || now if result.success?
      payment.update!(attributes)
    rescue ActiveRecord::RecordInvalid
      payment.update_columns(
        status: "unknown",
        failure_code: nil,
        provider_fee_minor: nil,
        provider_fee_currency: nil,
        raw_status: "verification_result_invalid",
        updated_at: now
      )
    end

    def status_for(result)
      return "succeeded" if result.success?
      return "failed" if result.failure?
      return "cancelled" if result.cancelled?
      return "timeout" if result.timeout?

      "unknown"
    end

    def grace_error(key, code:, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.payments.grace.errors.#{key}"),
        code:, status: :conflict, errors:
      )
    end

    class GraceFailure < Core::Error
      attr_reader :errors

      def initialize(error)
        @errors = error.respond_to?(:errors) ? error.errors : nil
        super(error.message)
      end
    end
  end
end
