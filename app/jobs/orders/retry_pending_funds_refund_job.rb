# frozen_string_literal: true

module Orders
  # Re-attempts only due liquidity-blocked obligations. A top-up signal can
  # invoke this job immediately; each command rechecks the refund row under its
  # own lock before making any provider call.
  class RetryPendingFundsRefundJob < ApplicationJob
    queue_as :payments
    retry_on StandardError, wait: :polynomially_longer, attempts: 10

    def perform
      Orders::Refund.where(status: "pending_funds")
        .where("next_retry_at IS NULL OR next_retry_at <= ?", Time.current)
        .find_each do |refund|
        result = Orders::SubmitRefund.call(refund:)
        raise result.error if result.failure?
      end
    end
  end
end
