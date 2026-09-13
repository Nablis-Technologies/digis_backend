# frozen_string_literal: true

module Marketplace
  # Shared seller-payout gates. Building and dispatching repeat the same
  # maturity, account, signed-ledger, and provider-liquidity checks so a
  # payout cannot become valid merely because the provider call happens later.
  module SellerPayoutSupport
    include Finance::PayoutSupport

    private

    def payout_error(key, code: key, status: :unprocessable_entity)
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.#{key}"), code:, status:
      )
    end

    def normalize_currency(currency)
      currency.to_s.strip.upcase
    end

    def valid_currency?(currency)
      currency.match?(/\A[A-Z]{3}\z/)
    end

    def seller_payout_scope_lock(seller_user_id:, currency:, event_id: nil)
      Core::Database::AdvisoryLock.acquire!(
        "marketplace-seller-payout", seller_user_id, currency, event_id || "all"
      )
    end

    def locked_seller(seller_user_id)
      Core::User.lock.find(seller_user_id)
    end

    def locked_account(account_id)
      SellerPayoutAccount.lock.find(account_id)
    end

    def account_scope_valid?(account, seller_id:, provider: nil)
      account.user_id == seller_id && account.verified? &&
        (provider.blank? || account.provider == provider)
    end

    def remaining_ledger_amount(entry, allocation_totals)
      entry.amount_minor.abs - allocation_totals.fetch(entry.id, 0)
    end

    def signed_allocation_total(allocations)
      allocations.sum do |allocation|
        ledger_amount = allocation.seller_ledger_entry.amount_minor
        allocation.amount_minor * (ledger_amount.positive? ? 1 : -1)
      end
    end

    def provider_balance(adapter, currency)
      capabilities = adapter.capabilities.to_h.deep_symbolize_keys
      if capabilities.dig(:balance_api, :supported) == false
        return success(balance_api_supported: false, currency: currency)
      end

      balance = adapter.available_balance(currency:)
      return failure(payout_error(:seller_payout_provider_unavailable)) if balance.nil?

      attributes = balance.to_h.deep_symbolize_keys
      amount = attributes.fetch(:amount_minor)
      balance_currency = normalize_currency(attributes.fetch(:currency))
      unless amount.is_a?(Integer) && amount >= 0 && balance_currency == currency
        return failure(payout_error(:seller_payout_provider_balance_invalid))
      end

      success(attributes.merge(currency: balance_currency))
    rescue NotImplementedError
      failure(payout_error(:seller_payout_provider_unavailable))
    rescue KeyError, NoMethodError, TypeError
      failure(payout_error(:seller_payout_provider_balance_invalid))
    end

    def provider_reserve_target(provider:, currency:)
      Finance::ProviderReservePolicy.where(provider:, currency:).pick(:target_minor) || 0
    end

    def normalize_provider_result(response)
      Marketplace::PayoutProviders::Result.from_provider_response(response)
    rescue ArgumentError, NoMethodError, TypeError
      raise ArgumentError, I18n.t("marketplace.resale.errors.seller_payout_provider_result_invalid")
    end
  end
end
