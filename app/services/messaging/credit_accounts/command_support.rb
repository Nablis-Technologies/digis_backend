# frozen_string_literal: true

module Messaging
  module CreditAccounts
    # Shared locking, idempotency, and ledger evidence helpers for credit
    # transitions. Provider calls never cross this boundary.
    module CommandSupport
      private

      def idempotency_key
        @idempotency_key ||= Core::IdempotencyKey.new(@raw_idempotency_key)
      end

      def idempotency_digest(operation)
        Core::KeyedDigest.digest(
          namespace: "messaging-credit-#{operation}", value: idempotency_key.to_s
        )
      end

      def account_for!(account, organization)
        return account if account.organization_id == organization.id

        raise business_error(:credit_account_scope_invalid, :forbidden)
      end

      def append_entry!(account:, entry_type:, quantity:, available_delta:, rate_version: nil,
        rate_version_id: nil,
        reference_type: nil, reference_id: nil, operation:, metadata: {}, ledger_idempotency_key: nil)
        CreditLedgerEntry.create!(
          credit_account: account,
          rate_version_id: rate_version_id || rate_version&.id,
          entry_type:,
          quantity:,
          available_delta:,
          reference_type:,
          reference_id:,
          idempotency_key_digest: ledger_idempotency_key || idempotency_digest(operation),
          metadata:
        )
      end

      def business_error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("messaging.errors.#{key}"), code: key.to_s, status:, errors:
        )
      end

      def failure_result(key, status = :unprocessable_entity, errors: nil)
        failure(business_error(key, status, errors:))
      end

      def rescue_invalid_operation
        yield
      rescue ArgumentError
        failure_result(:invalid_idempotency_key)
      rescue ActiveRecord::RecordInvalid => exception
        failure_result(:invalid_credit_operation, errors: exception.record.errors.to_hash)
      rescue ActiveRecord::RecordNotFound
        failure_result(:invalid_credit_operation)
      rescue ActiveRecord::RecordNotUnique
        failure_result(:credit_idempotency_conflict, :conflict)
      end

      def resolve_reservation!(status:, entry_type:, available_delta:, resolution_code:)
        # The reservation transition and compensating ledger entry commit as
        # one unit. A terminal row may replay the same result, but a different
        # resolution is rejected rather than appending contradictory evidence.
        rescue_invalid_operation do
          ActiveRecord::Base.transaction do
            account = CreditAccount.lock.find(@reservation.credit_account_id)
            reservation = CreditReservation.lock.find(@reservation.id)
            if reservation.terminal?
              return success(reservation) if reservation.status == status &&
                reservation.resolution_code == resolution_code

              return failure_result(:reservation_already_resolved, :conflict)
            end

            reservation.update!(status:, resolved_at: @at, resolution_code:)
            append_entry!(
              account:, rate_version: reservation.rate_version,
              entry_type:, quantity: reservation.quantity,
              available_delta: available_delta == :quantity ? reservation.quantity : available_delta,
              reference_type: "Messaging::CreditReservation", reference_id: reservation.id,
              operation: "#{entry_type}:#{reservation.id}:#{idempotency_key}",
              metadata: resolution_code.present? ? { "reason" => resolution_code } : {}
            )
            success(reservation)
          end
        end
      rescue Core::BusinessError => exception
        failure(exception)
      end
    end
  end
end
