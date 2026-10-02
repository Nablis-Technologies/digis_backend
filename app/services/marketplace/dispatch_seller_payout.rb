# frozen_string_literal: true

module Marketplace
  # Commits seller-payout processing intent before calling the provider. A
  # timeout therefore enters reconciliation instead of blindly submitting the
  # same destination transfer a second time; provider success/failure is
  # applied by the shared result command afterward.
  class DispatchSellerPayout < Core::BaseService
    include SellerPayoutSupport

    def initialize(payout:, adapter:, at: Time.current)
      @payout_id = payout.id
      @adapter = adapter
      @at = at.to_time.utc
    end

    def call
      gate_result = persist_processing_intent
      return gate_result if gate_result.failure?
      return gate_result if gate_result.value.succeeded?

      payout = gate_result.value
      account = SellerPayoutAccount.find(payout.seller_payout_account_id)
      result = normalize_provider_result(adapter.payout(**destination_payload(payout, account)))
      handle_provider_result(result)
    rescue ActiveRecord::RecordNotFound
      failure(payout_error(:seller_payout_not_found, code: "seller_payout_not_found", status: :not_found))
    rescue ActiveRecord::RecordInvalid
      failure(payout_error(:seller_payout_ledger_invalid, code: "seller_payout_ledger_invalid", status: :conflict))
    rescue NotImplementedError
      failure(payout_error(:seller_payout_provider_unavailable))
    rescue ArgumentError, NoMethodError, TypeError
      failure(payout_error(:seller_payout_provider_result_invalid))
    end

    private

    attr_reader :payout_id, :adapter, :at

    def destination_payload(payout, account)
      {
        amount_minor: payout.amount_minor,
        currency: payout.currency,
        idempotency_key: payout.idempotency_key,
        payout_id: payout.id,
        account_number: account.account_number,
        account_name: account.holder_name,
        bank_slug: account.bank_slug
      }
    end

    def persist_processing_intent
      payout = Marketplace::ApplicationRecord.transaction do
        current = SellerPayout.lock.find(payout_id)
        return success(current) if current.succeeded?
        return failure(payout_error(:seller_payout_not_dispatchable)) unless current.pending?

        seller = locked_seller(current.seller_user_id)
        account = locked_account(current.seller_payout_account_id)
        return failure(payout_error(:seller_payout_seller_ineligible)) if seller.deactivated?
        return failure(payout_error(:payout_account_not_verified)) unless account_scope_valid?(account, seller_id: seller.id, provider: current.provider)

        allocations = locked_allocations(current)
        gate_error = dispatch_gate_error(current, allocations)
        return failure(gate_error) if gate_error

        current.update!(status: "processing")
        account.update!(last_used_at: at)
        account.record_audit!(
          "marketplace.seller_payout_account.used",
          audited_changes: { last_used_at: at.iso8601 },
          metadata: { account_id: account.id, payout_id: current.id },
          audit_key: "marketplace-seller-payout-account-used-#{current.id}"
        )
        current
      end
      success(payout)
    end

    def locked_allocations(payout)
      SellerPayoutAllocation
        .where(payout_id: payout.id, status: "reserved")
        .includes(seller_ledger_entry: :event)
        .order(:id)
        .lock
        .to_a
    end

    def dispatch_gate_error(payout, allocations)
      return payout_error(:seller_payout_not_dispatchable) if allocations.empty?
      return payout_error(:seller_payout_scope_mismatch) unless signed_allocation_total(allocations) == payout.amount_minor
      return payout_error(:seller_payout_scope_mismatch) unless allocations.all? { |allocation| allocation_scope_valid?(payout, allocation) }

      balance_result = provider_balance(adapter, payout.currency)
      return balance_result.error if balance_result.failure?
      return nil if balance_result.value[:balance_api_supported] == false

      target = provider_reserve_target(provider: payout.provider, currency: payout.currency)
      return payout_error(:seller_payout_provider_reserve_breach) if balance_result.value.fetch(:amount_minor) < payout.amount_minor + target

      nil
    end

    def allocation_scope_valid?(payout, allocation)
      entry = allocation.seller_ledger_entry
      return false unless entry.seller_user_id == payout.seller_user_id && entry.currency == payout.currency
      return false unless entry.available_at <= at
      return true if entry.amount_minor.negative?

      positive_entry_eligible?(entry, at:)
    end

    def handle_provider_result(result)
      if result.success? || result.failure? || result.cancelled?
        return ApplySellerPayoutResult.call(
          payout: SellerPayout.find(payout_id), result:, at:
        )
      end

      ReconcileSellerPayoutJob.perform_later(payout_id)
      success(SellerPayout.find(payout_id))
    end
  end
end
