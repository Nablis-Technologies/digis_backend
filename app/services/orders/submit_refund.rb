# frozen_string_literal: true

module Orders
  # Moves one durable refund obligation into provider processing and applies
  # the normalized response. Database locks cover only the state transition;
  # balance and provider calls happen after commit, so a crash leaves a
  # processing row for verification instead of enabling a blind resubmission.
  class SubmitRefund < Core::BaseService
    PENDING_FUNDS_RETRY_DELAY = 15.minutes

    def initialize(refund:, reserve_target_minor: 0, now: Time.current)
      @refund = refund
      # The reserve is a discretionary-outflow floor for payouts, never a
      # reason to reduce or block a legitimate buyer refund.
      @reserve_target_minor = reserve_target_minor.to_i
      @now = now.to_time.utc
    end

    def call
      snapshot = load_snapshot
      return success(snapshot[:refund]) if snapshot[:skip]

      adapter = fetch_adapter(snapshot[:provider])
      capabilities = refund_capabilities(adapter)
      capability_failure = validate_capabilities(snapshot, capabilities)
      return failure(capability_failure) if capability_failure

      if insufficient_balance?(adapter, snapshot, capabilities)
        pending = mark_pending_funds(snapshot[:refund_id])
        return success(pending)
      end

      transition, claimed = mark_processing(snapshot[:refund_id])
      return success(transition) unless claimed

      provider_result = adapter.refund(
        payment_id: snapshot[:payment_id],
        provider_reference: snapshot[:provider_reference],
        amount_minor: snapshot[:amount_minor],
        currency: snapshot[:currency],
        idempotency_key: snapshot[:idempotency_key]
      )
      applied = Orders::ApplyRefundResult.call(refund: transition, result: provider_result, now:)
      return failure(applied.error) if applied.failure?

      success(applied.value)
    rescue KeyError
      failure(refund_error(:provider_unavailable, code: "provider_unavailable", status: :service_unavailable))
    rescue NotImplementedError
      failure(refund_error(:provider_refund_unsupported, code: "provider_refund_unsupported"))
    rescue ActiveRecord::RecordNotFound
      failure(refund_error(:refund_not_found, code: "refund_not_found"))
    end

    private

    attr_reader :refund, :reserve_target_minor, :now

    def load_snapshot
      ActiveRecord::Base.transaction do
        locked_refund = Orders::Refund.lock.find(refund.id)
        if locked_refund.status.in?(%w[succeeded failed processing])
          next { skip: true, refund: locked_refund }
        end
        if locked_refund.status == "pending_funds" &&
            locked_refund.next_retry_at.present? && locked_refund.next_retry_at > now
          next { skip: true, refund: locked_refund }
        end

        payment = Orders::Payment.find(locked_refund.payment_id)
        {
          refund_id: locked_refund.id,
          provider: payment.provider,
          payment_id: payment.id,
          provider_reference: payment.provider_reference,
          amount_minor: locked_refund.amount_minor,
          currency: locked_refund.currency,
          idempotency_key: locked_refund.idempotency_key,
          payment_amount_minor: payment.amount_minor,
          refund_type: locked_refund.type
        }
      end
    end

    def fetch_adapter(provider)
      Payments::Providers::Registry.fetch(provider)
    end

    def refund_capabilities(adapter)
      adapter.refund_capabilities
    end

    def validate_capabilities(snapshot, capabilities)
      return refund_error(:provider_refund_unsupported, code: "provider_refund_unsupported") unless capabilities[:supported]

      partial = snapshot[:amount_minor] < snapshot[:payment_amount_minor]
      return if !partial || capabilities[:partial]

      refund_error(:provider_partial_refund_unsupported, code: "provider_partial_refund_unsupported")
    end

    def insufficient_balance?(adapter, snapshot, capabilities)
      balance = adapter.available_balance(currency: snapshot[:currency])
      return false unless balance.is_a?(Hash)

      normalized = balance.deep_symbolize_keys
      amount = normalized[:amount_minor]
      currency = normalized[:currency].to_s.upcase
      return false unless amount.is_a?(Integer) && amount >= 0 && currency == snapshot[:currency]

      amount < snapshot[:amount_minor] + capabilities[:fee_estimate_minor]
    rescue StandardError
      false
    end

    def mark_pending_funds(refund_id)
      ActiveRecord::Base.transaction do
        Orders::Refund.lock.find(refund_id).tap do |locked_refund|
          locked_refund.update!(
            status: "pending_funds",
            pending_reason: "insufficient_funds",
            next_retry_at: now + PENDING_FUNDS_RETRY_DELAY
          ) if locked_refund.status.in?(%w[created pending_funds])
        end
      end
    end

    def mark_processing(refund_id)
      ActiveRecord::Base.transaction do
        locked_refund = Orders::Refund.lock.find(refund_id)
        if locked_refund.status.in?(%w[created pending_funds])
          locked_refund.update!(status: "processing", pending_reason: nil, next_retry_at: nil)
          [ locked_refund, true ]
        else
          [ locked_refund, false ]
        end
      end
    end

    def refund_error(key, code:, status: :conflict)
      Core::BusinessError.new(I18n.t("orders.refunds.errors.#{key}"), code:, status:)
    end
  end
end
