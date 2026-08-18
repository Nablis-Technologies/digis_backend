# frozen_string_literal: true

module Finance
  # Converts one canonical provider result into the durable payout/accounting
  # transition. Dispatch and reconciliation both use this command so success,
  # failure, and cancellation cannot diverge across recovery paths.
  class ApplyPayoutResult < Core::BaseService
    include Finance::PayoutSettlement

    def initialize(payout:, result:, at: Time.current)
      @payout_id = payout.id
      @result = result
      @at = at.to_time.utc
    end

    def call
      if result.success?
        return success(settle_payout_success(
          payout_id:, provider_reference: result.provider_reference, at:
        ))
      end

      if result.failure? || result.cancelled?
        return success(settle_payout_failure(
          payout_id:, status: result.cancelled? ? "cancelled" : "failed",
          failure_code: result.failure_code || result.status, at:
        ))
      end

      success(Finance::Payout.find(payout_id))
    rescue ActiveRecord::RecordInvalid
      failure(Core::BusinessError.new(
        I18n.t("finance.errors.payout_ledger_entry_invalid"),
        code: "payout_ledger_entry_invalid", status: :conflict
      ))
    end

    private

    attr_reader :payout_id, :result, :at
  end
end
