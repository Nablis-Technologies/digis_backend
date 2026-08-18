# frozen_string_literal: true

module Finance
  # Resolves a processing payout through the provider's verification endpoint.
  # A second submission is never attempted after an unknown or timeout result.
  class ReconcilePayout < Core::BaseService
    def initialize(payout:, adapter:, at: Time.current)
      @payout_id = payout.id
      @adapter = adapter
      @at = at.to_time.utc
    end

    def call
      payout = Finance::Payout.lock.find(payout_id)
      return success(payout) unless payout.processing?

      result = Finance::PayoutProviders::Result.from_provider_response(
        adapter.verify_payout(
          idempotency_key: payout.idempotency_key,
          payout_id: payout.id,
          provider_reference: payout.provider_reference
        )
      )
      Finance::ApplyPayoutResult.call(payout:, result:, at:)
    rescue ActiveRecord::RecordNotFound
      failure(Core::BusinessError.new(
        I18n.t("finance.errors.payout_not_found"), code: "payout_not_found", status: :not_found
      ))
    rescue ArgumentError, NoMethodError, TypeError
      failure(Core::BusinessError.new(
        I18n.t("finance.errors.payout_provider_result_invalid"),
        code: "payout_provider_result_invalid", status: :unprocessable_entity
      ))
    end

    private

    attr_reader :payout_id, :adapter, :at
  end
end
