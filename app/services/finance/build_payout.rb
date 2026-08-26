# frozen_string_literal: true

module Finance
  # Reserves one positive organizer payout from immutable ledger facts. The
  # organization row is the deterministic scope lock; ledger rows and their
  # existing allocations are then locked by ID before any new reservation is
  # inserted, preventing two builders from cashing out the same fact.
  class BuildPayout < Core::BaseService
    include Finance::PayoutSupport

    def initialize(organization:, currency:, idempotency_key:, amount_minor: nil,
      cutoff_at: Time.current, at: Time.current)
      @organization_id = organization.id
      @currency = normalize_currency(currency)
      @idempotency_key = idempotency_key.to_s
      @requested_amount = amount_minor
      @cutoff_at = cutoff_at.to_time.utc
      @at = at.to_time.utc
    end

    def call
      return failure(finance_error(:payout_amount_invalid, status: :unprocessable_entity)) if invalid_amount?

      payout = ActiveRecord::Base.transaction do
        payout_scope_lock(organization_id:, currency:)
        existing = Finance::Payout.lock.find_by(idempotency_key: idempotency_key)
        next existing if existing

        organization_lock(organization_id)
        payout_account = locked_default_payout_account
        return failure(finance_error(:payout_account_required, code: "payout_account_required")) unless payout_account

        entries = locked_entries
        allocation_totals = locked_allocation_totals(entries)
        candidate = calculate_candidate(entries, allocation_totals)
        return failure(candidate) if candidate.is_a?(Core::BusinessError)

        create_payout!(candidate, payout_account)
      end

      success(payout)
    rescue ActiveRecord::RecordNotUnique
      replay = Finance::Payout.find_by(idempotency_key: idempotency_key)
      replay ? success(replay) : failure(finance_error(:payout_scope_mismatch, code: "payout_build_conflict", status: :conflict))
    rescue ActiveRecord::RecordInvalid
      failure(finance_error(:payout_scope_mismatch, code: "payout_build_conflict", status: :conflict))
    rescue ActiveRecord::RecordNotFound
      failure(finance_error(:source_not_found, code: "source_not_found", status: :not_found))
    end

    private

    attr_reader :organization_id, :currency, :idempotency_key, :requested_amount, :cutoff_at, :at

    def invalid_amount?
      requested_amount.present? && (!requested_amount.is_a?(Integer) || requested_amount <= 0)
    end

    def locked_entries
      Finance::LedgerEntry
        .where(organization_id:, currency:)
        .where("available_at <= ?", cutoff_at)
        .where.not(type: "payout")
        .includes(event: :event_dates)
        .order(Arel.sql("CASE WHEN amount_minor < 0 THEN 0 ELSE 1 END"), :id)
        .lock
        .to_a
    end

    def locked_allocation_totals(entries)
      return {} if entries.empty?

      allocations = Finance::PayoutAllocation
        .where(ledger_entry_id: entries.map(&:id), status: %w[reserved consumed])
        .order(:ledger_entry_id, :id)
        .lock
        .to_a
      allocations.group_by(&:ledger_entry_id).transform_values do |rows|
        rows.sum { |row| row.amount_minor.abs }
      end
    end

    def locked_default_payout_account
      Finance::PayoutAccount
        .where(organization_id:, status: "verified", is_default: true)
        .lock
        .first
    end

    def calculate_candidate(entries, allocation_totals)
      positive_entries = entries.select do |entry|
        remaining = remaining_amount(entry, allocation_totals)
        remaining.positive? && positive_entry_eligible?(entry, at:)
      end
      negative_entries = entries.select do |entry|
        remaining_amount(entry, allocation_totals).positive? && entry.amount_minor.negative?
      end

      if positive_entries.empty?
        return finance_error(:payout_not_matured, code: "payout_not_matured") if entries.any? { |entry| entry.amount_minor.positive? }

        return finance_error(:payout_balance_not_positive, code: "payout_balance_not_positive")
      end

      net_amount = negative_entries.sum { |entry| -remaining_amount(entry, allocation_totals) } +
        positive_entries.sum { |entry| remaining_amount(entry, allocation_totals) }
      return finance_error(:payout_balance_not_positive, code: "payout_balance_not_positive") unless net_amount.positive?

      amount = requested_amount || net_amount
      return finance_error(:payout_amount_invalid, code: "payout_amount_invalid") if amount > net_amount

      allocations = build_allocations(
        negative_entries, positive_entries, allocation_totals, amount
      )
      { amount_minor: amount, allocations: }
    end

    def remaining_amount(entry, allocation_totals)
      entry.amount_minor.abs - allocation_totals.fetch(entry.id, 0)
    end

    def build_allocations(negative_entries, positive_entries, allocation_totals, target)
      rows = negative_entries.map do |entry|
        { ledger_entry_id: entry.id, amount_minor: -remaining_amount(entry, allocation_totals) }
      end
      required_positive = target - rows.sum { |row| row.fetch(:amount_minor) }

      positive_entries.each do |entry|
        break if required_positive <= 0

        amount = [ remaining_amount(entry, allocation_totals), required_positive ].min
        rows << { ledger_entry_id: entry.id, amount_minor: amount }
        required_positive -= amount
      end

      rows
    end

    def create_payout!(candidate, payout_account)
      payout = Finance::Payout.create!(
        organization_id: organization_id,
        payout_account: payout_account,
        currency: currency,
        status: "pending",
        amount_minor: candidate.fetch(:amount_minor),
        idempotency_key: idempotency_key,
        period_end: cutoff_at,
        requested_at: at
      )
      ledger_entries = Finance::LedgerEntry.where(
        id: candidate.fetch(:allocations).map { |attributes| attributes.fetch(:ledger_entry_id) }
      ).index_by(&:id)
      candidate.fetch(:allocations).each do |attributes|
        payout.allocations.create!(
          attributes.merge(status: "reserved", ledger_entry: ledger_entries.fetch(attributes.fetch(:ledger_entry_id)))
        )
      end
      payout
    end
  end
end
