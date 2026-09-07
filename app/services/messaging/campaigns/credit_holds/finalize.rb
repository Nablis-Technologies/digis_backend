# frozen_string_literal: true

module Messaging
  module Campaigns
    module CreditHolds
      # Settles any unallocated remainder and closes the aggregate hold once.
      class Finalize < Core::BaseService
        include Messaging::CreditAccounts::CommandSupport

        def initialize(reservation:, resolution_code: "campaign_finalized")
          @reservation = reservation
          @resolution_code = resolution_code.to_s.strip.presence || "campaign_finalized"
          @at = Time.current
        end

        def call
          ActiveRecord::Base.transaction do
            hold = CreditReservation.lock.find(@reservation.id)
            return success(hold) if hold.terminal?
            return failure_result(:credit_hold_unsettled, :conflict) if hold.allocations.where(status: "allocated").exists?

            allocated_quantity = hold.allocations.sum(:quantity)
            remainder = hold.quantity - allocated_quantity
            if remainder.positive?
              account = CreditAccount.lock.find(hold.credit_account_id)
              append_entry!(
                account:, rate_version: hold.rate_version, entry_type: "release", quantity: remainder,
                available_delta: remainder, reference_type: "Messaging::CreditReservation", reference_id: hold.id,
                operation: "campaign-hold-finalize-#{hold.id}-#{@resolution_code}",
                ledger_idempotency_key: ledger_idempotency_key(hold), metadata: { "reason" => @resolution_code }
              )
            end
            hold.update!(status: remainder.positive? ? "released" : "consumed", resolved_at: @at,
              resolution_code: @resolution_code)
            success(hold)
          end
        rescue ActiveRecord::RecordInvalid => exception
          failure_result(:credit_hold_invalid, errors: exception.record.errors.to_hash)
        end

        private

        def ledger_idempotency_key(hold)
          Core::KeyedDigest.digest(
            namespace: "messaging-credit-finalize", value: "#{hold.id}:#{@resolution_code}"
          )
        end
      end
    end
  end
end
