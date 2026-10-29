# frozen_string_literal: true

module Finance
  # Dispatches a reserved payout only after rechecking maturity, allocation
  # totals, and the provider's live reserve. The processing intent is committed
  # before the provider call, making a timeout recoverable without blind retry.
  class DispatchPayout < Core::BaseService
    include Finance::PayoutSupport

    def initialize(payout:, adapter:, treasury_approval: nil, at: Time.current)
      @payout_id = payout.id
      @adapter = adapter
      @treasury_approval = treasury_approval
      @at = at.to_time.utc
    end

    def call
      gate_result = persist_processing_intent
      return gate_result if gate_result.failure?
      return gate_result if gate_result.value.paid?

      result = normalize_provider_result(adapter.payout(
        amount_minor: gate_result.value.amount_minor,
        currency: gate_result.value.currency,
        idempotency_key: gate_result.value.idempotency_key,
        payout_id: gate_result.value.id,
        account_number: gate_result.value.payout_account.account_number,
        account_name: gate_result.value.payout_account.account_name,
        bank_slug: gate_result.value.payout_account.bank_slug
      ))
      mark_payout_account_used!(gate_result.value)
      handle_provider_result(result)
    rescue ActiveRecord::RecordNotFound
      failure(finance_error(:payout_not_found, code: "payout_not_found", status: :not_found))
    rescue ActiveRecord::RecordInvalid
      failure(finance_error(:payout_ledger_entry_invalid, code: "payout_ledger_entry_invalid", status: :conflict))
    rescue NotImplementedError
      failure(finance_error(:payout_provider_unavailable, code: "payout_provider_unavailable", status: :unprocessable_entity))
    rescue ArgumentError, NoMethodError, TypeError
      failure(finance_error(:payout_provider_result_invalid, code: "payout_provider_result_invalid", status: :unprocessable_entity))
    end

    private

    attr_reader :payout_id, :adapter, :treasury_approval, :at

    def persist_processing_intent
      payout = Finance::ApplicationRecord.transaction do
        current = Finance::Payout.lock.includes(:organization, :payout_account).find(payout_id)
        return success(current) if current.paid?
        return failure(finance_error(:payout_not_dispatchable, code: "payout_not_dispatchable")) unless current.pending?
        return failure(finance_error(:payout_provider_unavailable, code: "payout_provider_unavailable")) if current.provider.blank? && adapter_provider.blank?

        allocations = locked_allocations(current)
        gate_error = dispatch_gate_error(current, allocations)
        return failure(gate_error) if gate_error

        current.update!(status: "processing", provider: current.provider || adapter_provider)
        current
      end
      success(payout)
    end

    def locked_allocations(payout)
      Finance::PayoutAllocation
        .where(payout_id: payout.id, status: "reserved")
        .includes(ledger_entry: { event: :event_dates })
        .order(:id)
        .lock
        .to_a
    end

    def dispatch_gate_error(payout, allocations)
      return finance_error(:payout_not_dispatchable, code: "payout_not_dispatchable") if allocations.empty?
      return finance_error(:payout_scope_mismatch, code: "payout_scope_mismatch") unless allocations.sum(&:amount_minor) == payout.amount_minor
      return finance_error(:payout_scope_mismatch, code: "payout_scope_mismatch") unless allocations.all? { |allocation| allocation_scope_valid?(payout, allocation) }
      return finance_error(:payout_account_required, code: "payout_account_required") unless payout_account_dispatchable?(payout)

      balance = provider_balance(payout.currency)
      if balance.nil?
        return nil if audited_treasury_approval?(payout)

        return finance_error(:treasury_approval_required, code: "treasury_approval_required")
      end

      amount = balance.fetch(:amount_minor)
      balance_currency = normalize_currency(balance.fetch(:currency))
      return finance_error(:provider_balance_invalid, code: "provider_balance_invalid") unless amount.is_a?(Integer) && amount >= 0 && balance_currency == payout.currency

      target = Finance::ProviderReservePolicy.where(provider: payout.provider || adapter_provider, currency: payout.currency).pick(:target_minor) || 0
      return finance_error(:provider_reserve_breach, code: "provider_reserve_breach") if amount < payout.amount_minor + target

      nil
    rescue KeyError
      finance_error(:provider_balance_invalid, code: "provider_balance_invalid")
    end

    def payout_account_dispatchable?(payout)
      payout.payout_account&.verified?
    end

    # Records the destination use attempt after the provider boundary returns;
    # provider success is recorded separately on the payout itself.
    def mark_payout_account_used!(payout)
      Finance::PayoutAccount.where(id: payout.payout_account_id).update_all(last_used_at: at)
    end

    def provider_balance(currency)
      adapter.available_balance(currency:)
    rescue NotImplementedError
      nil
    end

    def allocation_scope_valid?(payout, allocation)
      entry = allocation.ledger_entry
      return false unless entry.organization_id == payout.organization_id && entry.currency == payout.currency
      return false unless entry.available_at <= at
      return true if entry.amount_minor.negative?

      entry.event.present? && positive_entry_eligible?(entry, at:)
    end

    def audited_treasury_approval?(payout)
      approval = treasury_approval || Core::AuditLog
        .for_auditable(payout)
        .for_action("finance.payout.no_balance_api_approved")
        .where.not(actor_id: nil)
        .recent
        .first
      approval.is_a?(Core::AuditLog) &&
        approval.auditable_type == payout.class.name &&
        approval.auditable_id == payout.id &&
        approval.action == "finance.payout.no_balance_api_approved" &&
        approval.actor_id.present?
    end

    def adapter_provider
      adapter.class.const_get(:PROVIDER).to_s if adapter.class.const_defined?(:PROVIDER)
    end

    def normalize_provider_result(response)
      result = Finance::PayoutProviders::Result.from_provider_response(response)
      return result if result.is_a?(Finance::PayoutProviders::Result)

      raise ArgumentError
    end

    def handle_provider_result(result)
      if result.success?
        return Finance::ApplyPayoutResult.call(
          payout: Finance::Payout.find(payout_id), result:, at:
        )
      end

      if result.failure? || result.cancelled?
        return Finance::ApplyPayoutResult.call(
          payout: Finance::Payout.find(payout_id), result:, at:
        )
      end

      Finance::ReconcilePayoutJob.perform_later(payout_id)
      success(Finance::Payout.find(payout_id))
    end
  end
end
