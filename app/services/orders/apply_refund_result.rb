# frozen_string_literal: true

module Orders
  # Applies one normalized provider refund result to the immutable obligation.
  # A successful provider fee is stored as separate evidence and never changes
  # the buyer amount; unknown outcomes remain processing for verification.
  class ApplyRefundResult < Core::BaseService
    PROCESSING_RETRY_DELAY = 5.minutes

    def initialize(refund:, result:, now: Time.current)
      @refund = refund
      @now = now.to_time.utc
      @result = normalize_result(result)
    rescue ArgumentError, NoMethodError, TypeError => error
      @initialization_error = error
    end

    def call
      return failure(refund_error(:invalid_provider_result, code: "invalid_provider_result")) if @initialization_error
      return failure(refund_error(:invalid_provider_result, code: "invalid_provider_result")) unless valid_fee_evidence?

      refund = ActiveRecord::Base.transaction do
        locked_refund = Orders::Refund.lock.find(@refund.id)
        if locked_refund.status == "succeeded"
          apply_late_fee!(locked_refund) if @result.success? && provider_fee_present?
          revoke_gift_purchases!(locked_refund)
          post_finance_refund!(locked_refund)
          next locked_refund
        end
        next locked_refund if locked_refund.status == "failed"

        previous_status = locked_refund.status
        case @result.status
        when "success"
          locked_refund.update!(
            status: "succeeded",
            provider_reference: @result.provider_reference.presence || locked_refund.provider_reference,
            provider_fee_minor: @result.provider_fee_minor,
            provider_fee_currency: @result.provider_fee_currency,
            provider_fee_recorded_at: provider_fee_present? ? @now : nil,
            pending_reason: nil,
            next_retry_at: nil
          )
        when "failure", "cancelled"
          locked_refund.update!(
            status: "failed",
            provider_reference: @result.provider_reference.presence || locked_refund.provider_reference,
            pending_reason: @result.failure_code.presence || "provider_#{@result.status}",
            next_retry_at: nil
          )
        when "unknown", "timeout"
          locked_refund.update!(
            status: "processing",
            provider_reference: @result.provider_reference.presence || locked_refund.provider_reference,
            pending_reason: "provider_processing",
            next_retry_at: @now + PROCESSING_RETRY_DELAY
          )
        else
          raise ArgumentError, I18n.t("orders.refunds.errors.unsupported_provider_refund_status")
        end
        if locked_refund.status == "succeeded"
          revoke_gift_purchases!(locked_refund)
          post_finance_refund!(locked_refund)
        end
        publish_terminal_status!(locked_refund) if previous_status != locked_refund.status
        locked_refund
      end

      success(refund)
    rescue ActiveRecord::RecordNotFound
      failure(refund_error(:refund_not_found, code: "refund_not_found"))
    rescue ActiveRecord::RecordInvalid => error
      failure(
        refund_error(
          :invalid_provider_result,
          code: "invalid_provider_result",
          errors: error.record.errors.to_hash
        )
      )
    rescue ArgumentError
      failure(refund_error(:invalid_provider_result, code: "invalid_provider_result"))
    rescue Core::Error => error
      failure(error)
    end

    private

    attr_reader :refund

    def normalize_result(result)
      return result if result.is_a?(Payments::Providers::Result)

      Payments::Providers::Result.from_provider_response(result)
    end

    def valid_fee_evidence?
      fee_minor = @result.provider_fee_minor
      fee_currency = @result.provider_fee_currency
      return true if fee_minor.nil? && fee_currency.nil?

      fee_minor.is_a?(Integer) && fee_minor >= 0 && fee_currency == refund.currency
    end

    def provider_fee_present?
      @result.provider_fee_minor.present?
    end

    def apply_late_fee!(locked_refund)
      return unless provider_fee_present?
      return if locked_refund.provider_fee_minor == @result.provider_fee_minor &&
        locked_refund.provider_fee_currency == @result.provider_fee_currency

      locked_refund.update!(
        provider_fee_minor: @result.provider_fee_minor,
        provider_fee_currency: @result.provider_fee_currency,
        provider_fee_recorded_at: @now
      )
    end

    def publish_terminal_status!(locked_refund)
      return unless locked_refund.status.in?(%w[succeeded failed])

      result = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.refund.#{locked_refund.status}",
        aggregate: locked_refund,
        payload: {
          refund_id: locked_refund.id,
          payment_id: locked_refund.payment_id,
          status: locked_refund.status,
          refund_type: locked_refund.type
        },
        idempotency_key: "orders-refund-#{locked_refund.status}-#{locked_refund.id}"
      )
      raise result.error if result.failure?
    end

    # Refund state and its organizer reversal are committed together; a retry
    # reuses the refund-derived ledger key and therefore remains a no-op.
    def post_finance_refund!(locked_refund)
      result = Finance::PostRefund.call(refund: locked_refund, at: @now)
      raise result.error if result.failure?
    end

    def revoke_gift_purchases!(locked_refund)
      item_ids = Orders::RefundItem.where(refund_id: locked_refund.id).select(:order_item_id)
      gifts = Orders::GiftPurchase.where(order_item_id: item_ids)
        .includes(
          :recipient_user,
          order_item: { registration: [ :user, :created_by, :event, { ticket_type: { event_product: :event } } ] }
        )
        .lock.order(:id)
      gifts.each do |gift_purchase|
        result = GiftPurchases::Revoke.call(
          gift_purchase:, reason: "refunded", at: @now, row_locked: true
        )
        raise result.error if result.failure?
      end
    end

    def refund_error(key, code:, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.refunds.errors.#{key}"), code:, status: :conflict, errors:
      )
    end
  end
end
