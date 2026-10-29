# frozen_string_literal: true

module Marketplace
  # Reserves one seller payout from signed immutable ledger facts. The seller,
  # payout-account, and seller/event/currency scope locks are acquired before
  # ledger rows and existing allocations, preventing concurrent builders from
  # reserving the same proceeds or bypassing a newly posted reversal.
  class BuildSellerPayout < Core::BaseService
    include SellerPayoutSupport

    def initialize(seller:, account:, currency:, idempotency_key:, event: nil, amount_minor: nil,
      cutoff_at: Time.current, at: Time.current)
      @seller_id = seller.id
      @account_id = account.id
      @event_id = event&.id
      @currency = normalize_currency(currency)
      @idempotency_key = idempotency_key.to_s
      @requested_amount = amount_minor
      @cutoff_at = cutoff_at.to_time.utc
      @at = at.to_time.utc
    end

    def call
      return failure(payout_error(:seller_payout_currency_invalid)) unless valid_currency?(currency)
      return failure(payout_error(:seller_payout_amount_invalid)) if invalid_amount?

      payout = Marketplace::ApplicationRecord.transaction do
        seller_payout_scope_lock(seller_user_id: seller_id, currency:, event_id:)
        seller = locked_seller(seller_id)
        existing = SellerPayout.lock.find_by(idempotency_key:)
        if existing
          next existing if matching_request?(existing)

          next payout_error(:seller_payout_scope_mismatch, code: "seller_payout_build_conflict", status: :conflict)
        end

        account = locked_account(account_id)
        scope_error = account_scope_error(account, seller)
        next scope_error if scope_error

        entries = locked_entries
        allocation_totals = locked_allocation_totals(entries)
        candidate = calculate_candidate(entries, allocation_totals)
        next candidate if candidate.is_a?(Core::BusinessError)

        create_payout!(account:, candidate:)
      end

      return failure(payout) if payout.is_a?(Core::BusinessError)

      success(payout)
    rescue ActiveRecord::RecordNotUnique
      replay = SellerPayout.find_by(idempotency_key:)
      replay ? success(replay) : failure(payout_error(:seller_payout_scope_mismatch, code: "seller_payout_build_conflict", status: :conflict))
    rescue ActiveRecord::RecordInvalid
      failure(payout_error(:seller_payout_scope_mismatch, code: "seller_payout_build_conflict", status: :conflict))
    rescue ActiveRecord::RecordNotFound
      failure(payout_error(:seller_payout_source_not_found, code: "source_not_found", status: :not_found))
    end

    private

    attr_reader :seller_id, :account_id, :event_id, :currency, :idempotency_key, :requested_amount, :cutoff_at, :at

    def invalid_amount?
      requested_amount.present? && (!requested_amount.is_a?(Integer) || requested_amount <= 0)
    end

    def account_scope_error(account, seller)
      return payout_error(:seller_payout_seller_ineligible) if seller.deactivated?
      return payout_error(:payout_account_user_mismatch) unless account.user_id == seller.id
      return payout_error(:payout_account_not_verified) unless account.verified?

      nil
    end

    def matching_request?(payout)
      return false unless payout.seller_user_id == seller_id &&
        payout.seller_payout_account_id == account_id && payout.currency == currency
      return false if requested_amount.present? && payout.amount_minor != requested_amount

      event_ids = SellerPayoutAllocation.joins(:seller_ledger_entry)
        .where(payout_id: payout.id)
        .distinct
        .pluck("marketplace_seller_ledger_entries.event_id")
      event_id ? event_ids == [ event_id ] : event_ids.any?
    end

    def locked_entries
      scope = SellerLedgerEntry
        .where(seller_user_id: seller_id, currency:)
        .where("available_at <= ?", cutoff_at)
        .where.not(type: "payout")
      scope = scope.where(event_id:) if event_id
      scope.includes(:event).order(:id).lock.to_a
    end

    def locked_allocation_totals(entries)
      return {} if entries.empty?

      SellerPayoutAllocation
        .where(seller_ledger_entry_id: entries.map(&:id), status: %w[reserved consumed])
        .order(:seller_ledger_entry_id, :id)
        .lock
        .to_a
        .group_by(&:seller_ledger_entry_id)
        .transform_values { |rows| rows.sum(&:amount_minor) }
    end

    def calculate_candidate(entries, allocation_totals)
      positive_entries = entries.select do |entry|
        remaining_ledger_amount(entry, allocation_totals).positive? &&
          positive_entry_eligible?(entry, at:)
      end
      negative_entries = entries.select do |entry|
        remaining_ledger_amount(entry, allocation_totals).positive? && entry.amount_minor.negative?
      end

      if positive_entries.empty?
        return payout_error(:seller_payout_balance_not_positive)
      end

      net_amount = positive_entries.sum { |entry| remaining_ledger_amount(entry, allocation_totals) } -
        negative_entries.sum { |entry| remaining_ledger_amount(entry, allocation_totals) }
      return payout_error(:seller_payout_balance_not_positive) unless net_amount.positive?

      amount = requested_amount || net_amount
      return payout_error(:seller_payout_amount_invalid) if amount > net_amount

      { amount_minor: amount, allocations: build_allocations(negative_entries, positive_entries, allocation_totals, amount) }
    end

    def build_allocations(negative_entries, positive_entries, allocation_totals, target)
      rows = negative_entries.map do |entry|
        { seller_ledger_entry_id: entry.id, amount_minor: remaining_ledger_amount(entry, allocation_totals) }
      end
      required_positive = target + rows.sum { |row| row.fetch(:amount_minor) }

      positive_entries.each do |entry|
        break if required_positive <= 0

        amount = [ remaining_ledger_amount(entry, allocation_totals), required_positive ].min
        rows << { seller_ledger_entry_id: entry.id, amount_minor: amount }
        required_positive -= amount
      end
      rows
    end

    def create_payout!(account:, candidate:)
      payout = SellerPayout.create!(
        seller_user_id: seller_id,
        seller_payout_account_id: account.id,
        provider: account.provider,
        amount_minor: candidate.fetch(:amount_minor),
        currency:,
        status: "pending",
        idempotency_key:,
        requested_at: at
      )
      ledger_entries = SellerLedgerEntry.where(
        id: candidate.fetch(:allocations).map { |attributes| attributes.fetch(:seller_ledger_entry_id) }
      ).index_by(&:id)
      candidate.fetch(:allocations).each do |attributes|
        payout.seller_payout_allocations.create!(
          attributes.merge(seller_ledger_entry: ledger_entries.fetch(attributes.fetch(:seller_ledger_entry_id)))
        )
      end
      payout
    end
  end
end
