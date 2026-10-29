# frozen_string_literal: true

module Marketplace
  # Applies one canonical provider result under the payout lock. Allocation
  # consumption and the append-only seller payout ledger row commit together;
  # failure releases reservations without rewriting any seller economics.
  class ApplySellerPayoutResult < Core::BaseService
    include SellerPayoutSupport

    def initialize(payout:, result:, at: Time.current)
      @payout_id = payout.id
      @result = result
      @at = at.to_time.utc
    end

    def call
      if result.success?
        return success(settle_success)
      end

      if result.failure? || result.cancelled?
        return success(settle_failure(status: result.cancelled? ? "cancelled" : "failed"))
      end

      success(SellerPayout.find(payout_id))
    rescue ActiveRecord::RecordInvalid => error
      failure(Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.seller_payout_ledger_invalid"),
        code: "seller_payout_ledger_invalid", status: :conflict, errors: error.record.errors.to_hash
      ))
    end

    private

    attr_reader :payout_id, :result, :at

    def settle_success
      Marketplace::ApplicationRecord.transaction do
        payout = SellerPayout.lock.find(payout_id)
        return payout if payout.succeeded?
        return payout unless payout.processing?

        allocations = locked_allocations(payout)
        validate_payout_total!(payout, allocations)
        payout.update!(status: "succeeded", provider_reference: result.provider_reference,
          processed_at: at, failure_code: nil)
        allocations.each { |allocation| allocation.update!(status: "consumed", consumed_at: at, released_at: nil) }
        create_payout_ledger_entries!(payout, allocations)
        payout
      end
    end

    def settle_failure(status:)
      Marketplace::ApplicationRecord.transaction do
        payout = SellerPayout.lock.find(payout_id)
        return payout if payout.status.in?(%w[succeeded failed cancelled])

        SellerPayoutAllocation
          .where(payout_id: payout.id, status: "reserved")
          .includes(:payout, :seller_ledger_entry)
          .lock
          .to_a
          .each do |allocation|
          allocation.update!(status: "released", released_at: at, consumed_at: nil)
          end
        payout.update!(status:, processed_at: at, failure_code: result.failure_code || result.status)
        payout
      end
    end

    def locked_allocations(payout)
      SellerPayoutAllocation
        .where(payout_id: payout.id, status: %w[reserved consumed])
        .includes(:payout, seller_ledger_entry: :event)
        .order(:id)
        .lock
        .to_a
    end

    def validate_payout_total!(payout, allocations)
      return if signed_allocation_total(allocations) == payout.amount_minor

      raise ActiveRecord::RecordInvalid.new(payout), I18n.t(
        "marketplace.resale.errors.seller_payout_scope_mismatch"
      )
    end

    def create_payout_ledger_entries!(payout, allocations)
      debits_by_event = calculate_debits_by_event(payout, allocations)
      rows = payout_ledger_rows(payout, debits_by_event)
      existing_keys = SellerLedgerEntry.where(idempotency_key: rows.map { |row| row.fetch(:idempotency_key) })
        .pluck(:idempotency_key).index_with(true)
      new_rows = rows.reject { |row| existing_keys.key?(row.fetch(:idempotency_key)) }
      # The payout and its locked allocations establish these ledger attributes;
      # use one insert so multi-event payouts do not run per-row uniqueness queries.
      SellerLedgerEntry.insert_all!(new_rows, record_timestamps: false) if new_rows.any?
    end

    def calculate_debits_by_event(payout, allocations)
      remaining_amount = payout.amount_minor
      debits_by_event = Hash.new(0)

      positive_events = event_net_allocations(allocations)
        .select { |_event_id, net| net.positive? }
        .sort_by(&:first)

      positive_events.each do |event_id, net_capacity|
        break if remaining_amount.zero?

        debit = [ net_capacity, remaining_amount ].min
        debits_by_event[event_id] = debit
        remaining_amount -= debit
      end
      raise ActiveRecord::RecordInvalid.new(payout) if remaining_amount.positive?

      debits_by_event
    end

    def event_net_allocations(allocations)
      net_by_event = Hash.new(0)
      allocations.each do |allocation|
        entry = allocation.seller_ledger_entry
        multiplier = entry.amount_minor.positive? ? 1 : -1
        net_by_event[entry.event_id] += allocation.amount_minor * multiplier
      end
      net_by_event
    end

    def payout_ledger_rows(payout, debits_by_event)
      debits_by_event.select { |_event_id, debit| debit.positive? }.sort.map do |event_id, debit|
        {
          seller_user_id: payout.seller_user_id,
          event_id:,
          seller_payout_id: payout.id,
          type: "payout",
          amount_minor: -debit,
          currency: payout.currency,
          available_at: at,
          idempotency_key: "marketplace-seller-payout-#{payout.id}-#{event_id}",
          description: I18n.t("marketplace.resale.ledger_descriptions.seller_payout"),
          created_at: at
        }
      end
    end
  end
end
