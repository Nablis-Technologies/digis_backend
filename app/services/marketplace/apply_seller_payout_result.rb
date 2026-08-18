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
        create_payout_ledger_entry!(payout, allocations)
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

    def create_payout_ledger_entry!(payout, allocations)
      event_ids = allocations.map { |allocation| allocation.seller_ledger_entry.event_id }.uniq
      raise ActiveRecord::RecordInvalid.new(payout) if event_ids.one? == false

      SellerLedgerEntry.find_by(idempotency_key: "marketplace-seller-payout-#{payout.id}") ||
        SellerLedgerEntry.create!(
          seller_user_id: payout.seller_user_id,
          event_id: event_ids.first,
          seller_payout_id: payout.id,
          type: "payout",
          amount_minor: -payout.amount_minor,
          currency: payout.currency,
          available_at: at,
          idempotency_key: "marketplace-seller-payout-#{payout.id}",
          description: I18n.t("marketplace.resale.ledger_descriptions.seller_payout"),
          created_at: at
        )
    end
  end
end
