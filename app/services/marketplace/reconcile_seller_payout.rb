# frozen_string_literal: true

module Marketplace
  # Resolves an unknown seller payout through the provider verification
  # endpoint. A reconciliation path never submits the destination transfer a
  # second time after a timeout or crashed request.
  class ReconcileSellerPayout < Core::BaseService
    def initialize(payout:, adapter:, at: Time.current)
      @payout_id = payout.id
      @adapter = adapter
      @at = at.to_time.utc
    end

    def call
      payout = SellerPayout.lock.find(payout_id)
      return success(payout) unless payout.processing?

      result = Marketplace::PayoutProviders::Result.from_provider_response(
        adapter.verify_payout(
          idempotency_key: payout.idempotency_key,
          payout_id: payout.id,
          provider_reference: payout.provider_reference
        )
      )
      ApplySellerPayoutResult.call(payout:, result:, at:)
    rescue ActiveRecord::RecordNotFound
      failure(Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.seller_payout_not_found"),
        code: "seller_payout_not_found", status: :not_found
      ))
    rescue ArgumentError, NoMethodError, TypeError
      failure(Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.seller_payout_provider_result_invalid"),
        code: "seller_payout_provider_result_invalid", status: :unprocessable_entity
      ))
    end

    private

    attr_reader :payout_id, :adapter, :at
  end
end
