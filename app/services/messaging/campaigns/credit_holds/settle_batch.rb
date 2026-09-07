# frozen_string_literal: true

module Messaging
  module Campaigns
    module CreditHolds
      # Settles one provider-result page while each aggregate hold is locked once.
      class SettleBatch < Core::BaseService
        include Messaging::CreditAccounts::CommandSupport
        include SettlementSupport

        def initialize(outcomes:)
          @outcomes = Array(outcomes)
          @raw_idempotency_key = "campaign-settle-batch"
        end

        def call
          ActiveRecord::Base.transaction do
            allocations = CampaignCreditAllocation.where(id: @outcomes.map(&:allocation).map(&:id)).order(:id).lock.index_by(&:id)
            reservations = CreditReservation.where(id: allocations.values.map(&:credit_reservation_id).uniq).order(:id).lock.index_by(&:id)
            accounts = CreditAccount.where(id: reservations.values.map(&:credit_account_id).uniq).order(:id).lock.index_by(&:id)
            @outcomes.each { |outcome| settle_one(outcome, allocations.fetch(outcome.allocation.id), reservations, accounts) }
          end
          success(true)
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:credit_hold_invalid, message: exception.message))
        rescue Core::BusinessError => exception
          failure(exception)
        end

        private

        def settle_one(outcome, allocation, reservations, accounts)
          outcome_type = outcome.outcome.to_sym
          return if outcome_type == :retryable

          if allocation.terminal?
            raise settlement_conflict unless allocation.status == terminal_status_for(outcome_type)

            return
          end

          reservation = reservations.fetch(allocation.credit_reservation_id)
          account = accounts.fetch(reservation.credit_account_id)
          status, entry_type, available_delta, resolution = settlement_for(
            outcome: outcome_type, quantity: allocation.quantity, reason: outcome.reason
          )
          allocation.update_columns(
            status:, resolved_at: Time.current, resolution_code: resolution, updated_at: Time.current
          )
          append_entry!(
            account:, rate_version_id: reservation.rate_version_id, entry_type:, quantity: allocation.quantity,
            available_delta:, reference_type: "Messaging::CampaignDelivery", reference_id: allocation.delivery_id,
            operation: settlement_operation(allocation:, outcome: outcome_type),
            ledger_idempotency_key: settlement_ledger_digest(allocation:, outcome: outcome_type),
            metadata: { "reason" => resolution }
          )
        end

        def error(key, message: nil)
          Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s,
            status: :unprocessable_entity)
        end
      end
    end
  end
end
