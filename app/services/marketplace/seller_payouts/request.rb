# frozen_string_literal: true

module Marketplace
  module SellerPayouts
    # Reserves the seller's current net currency balance and records durable
    # dispatch intent before acknowledging the withdrawal request.
    class Request < Core::BaseService
      include CommandSupport

      class Abort < Core::Error
        attr_reader :business_error

        def initialize(business_error)
          @business_error = business_error
          super(business_error.message)
        end
      end

      def initialize(seller:, currency:, idempotency_key:, amount_minor: nil,
        seller_payout_account_id: nil, at: Time.current)
        @seller = seller
        @seller_id = seller&.id
        @currency = currency.to_s.strip.upcase
        @raw_idempotency_key = idempotency_key
        @amount_minor = amount_minor
        @requested_account_id = seller_payout_account_id.to_s.strip.presence
        @at = at.to_time.utc
      rescue ArgumentError, NoMethodError => error
        @initialization_error = error
      end

      def call
        return failure(command_error(:invalid_idempotency_key, code: "invalid_idempotency_key")) if @initialization_error
        return failure(command_error(:seller_payout_seller_ineligible)) if seller_id.blank? || seller.deactivated?
        return failure(command_error(:seller_payout_currency_invalid)) unless currency.match?(/\A[A-Z]{3}\z/)
        return failure(command_error(:seller_payout_amount_invalid)) if invalid_amount?

        command_key = normalized_command_key
        request_digest = command_request_digest(
          operation: "withdraw",
          account_id: requested_account_id,
          actor: seller,
          identity: { currency:, amount_minor: }
        )
        audit_key = command_audit_key("withdraw", command_key)

        execute_request(command_key, request_digest, audit_key)
      rescue ArgumentError
        failure(command_error(:invalid_idempotency_key, code: "invalid_idempotency_key"))
      rescue ActiveRecord::RecordNotFound
        failure(command_error(
          :seller_payout_source_not_found, code: "seller_payout_source_not_found", status: :not_found
        ))
      rescue ActiveRecord::RecordNotUnique
        failure(command_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
      rescue Core::Audit::Record::ReplayConflict, Core::Outbox::Publish::IdempotencyConflict
        failure(command_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
      end

      private

      attr_reader :seller, :seller_id, :currency, :raw_idempotency_key,
                  :amount_minor, :requested_account_id, :at

      def invalid_amount?
        amount_minor.present? && (!amount_minor.is_a?(Integer) || amount_minor <= 0)
      end

      def normalized_command_key
        client_key = normalize_command_key(raw_idempotency_key)
        Core::IdempotencyKey.new("marketplace-seller-#{seller_id}-#{client_key.digest}")
      end

      def execute_request(command_key, request_digest, audit_key)
        ActiveRecord::Base.transaction do
          Core::Database::AdvisoryLock.acquire!(
            "marketplace-seller-payout-request", seller_id, command_key.digest
          )

          replay = replay_result(audit_key:, request_digest:)
          next replay if replay

          account = payout_account
          next failure(command_error(:seller_payout_account_required)) unless account

          payout_result = build_payout(account, command_key)
          next payout_result if payout_result.failure?

          payout = payout_result.value
          record_request!(payout, request_digest, audit_key)
          publish_request!(payout)
          success(payout)
        end
      rescue Abort => error
        failure(error.business_error)
      end

      def payout_account
        accounts = SellerPayoutAccount.where(
          user_id: seller_id, provider: "chapa", status: "verified"
        )
        return accounts.find_by(id: requested_account_id) if requested_account_id

        accounts.where(is_default: true).order(verified_at: :desc, id: :desc).first
      end

      def build_payout(account, command_key)
        BuildSellerPayout.call(
          seller:,
          account:,
          currency:,
          amount_minor:,
          cutoff_at: at,
          at:,
          idempotency_key: "marketplace-seller-payout-#{seller_id}-#{command_key.digest}"
        )
      end

      def record_request!(payout, request_digest, audit_key)
        event_ids = payout.seller_payout_allocations
          .joins(:seller_ledger_entry)
          .distinct
          .pluck("marketplace_seller_ledger_entries.event_id")
          .sort
        result = Core::Audit::Record.call(
          audit_key:,
          action: "marketplace.seller_payout.requested",
          auditable_type: payout.class.name,
          auditable_id: payout.id,
          actor_type: seller.class.name,
          actor_id: seller.id,
          audited_changes: { status: [ nil, payout.status ] },
          metadata: {
            request_digest:,
            payout_id: payout.id,
            seller_user_id: seller_id,
            seller_payout_account_id: payout.seller_payout_account_id,
            event_ids:,
            amount_minor: payout.amount_minor,
            currency: payout.currency
          }
        )
        raise Abort, result.error if result.failure?
      end

      def publish_request!(payout)
        result = Core::Outbox::Publish.call(
          topic: "marketplace",
          event_type: "marketplace.seller_payout.requested",
          aggregate: payout,
          payload: { payout_id: payout.id },
          idempotency_key: "marketplace-seller-payout-requested-#{payout.id}"
        )
        raise Abort, result.error if result.failure?
      end
    end
  end
end
