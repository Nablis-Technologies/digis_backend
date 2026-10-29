# frozen_string_literal: true

module Messaging
  module Campaigns
    module CreditHolds
      # Converts one delivery allocation into immutable credit evidence.
      # Fan-out uses SettleBatch; this one-row primitive remains the tested
      # command for isolated callers and settlement identity verification.
      class Settle < Core::BaseService
        include Messaging::CreditAccounts::CommandSupport
        include SettlementSupport

        OUTCOMES = SettlementSupport::OUTCOMES

        def initialize(allocation:, outcome:, idempotency_key:, reason: nil)
          @allocation = allocation
          @outcome = outcome.to_s.strip.downcase.to_sym
          @raw_idempotency_key = idempotency_key
          @reason = reason.to_s.strip.presence
          @at = Time.current
        end

        def call
          Core::IdempotencyKey.new(@raw_idempotency_key)
          return failure(error(:credit_hold_invalid)) unless @allocation.is_a?(CampaignCreditAllocation) && OUTCOMES.include?(@outcome)
          return success(@allocation) if @outcome == :retryable

          ActiveRecord::Base.transaction do
            allocation = CampaignCreditAllocation.lock.find(@allocation.id)
            return replay(allocation) if allocation.terminal?

            reservation = CreditReservation.lock.find(allocation.credit_reservation_id)
            account = CreditAccount.lock.find(reservation.credit_account_id)
            status, entry_type, available_delta, resolution = settlement
            allocation.update!(status:, resolved_at: @at, resolution_code: resolution)
            append_entry!(
              account:, rate_version: reservation.rate_version, entry_type:,
              quantity: allocation.quantity, available_delta:,
              reference_type: "Messaging::CampaignDelivery", reference_id: allocation.delivery_id,
              operation: settlement_operation(allocation:, outcome: @outcome),
              ledger_idempotency_key: settlement_ledger_digest(allocation:, outcome: @outcome),
              metadata: { "reason" => resolution }
            )
            success(allocation)
          end
        rescue ArgumentError => exception
          failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:credit_hold_invalid, message: exception.message))
        end

        private

        def settlement
          settlement_for(outcome: @outcome, quantity: @allocation.quantity, reason: @reason)
        end

        def replay(allocation)
          expected = terminal_status_for(@outcome)
          return success(allocation) if allocation.status == expected

          failure(error(:credit_idempotency_conflict, status: :conflict))
        end

        def error(key, message: nil, status: :unprocessable_entity)
          Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
        end
      end
    end
  end
end
