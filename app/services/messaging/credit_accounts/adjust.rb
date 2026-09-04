# frozen_string_literal: true

module Messaging
  module CreditAccounts
    # Appends an audited platform correction without mutating prior evidence.
    class Adjust < Core::BaseService
      include CommandSupport

      PERMISSION = "messaging_credit_adjustment.create"

      def initialize(account:, organization:, quantity:, actor:, reason:, idempotency_key:,
        rate_version: nil, at: Time.current)
        @account = account
        @organization = organization
        @quantity = quantity
        @actor = actor
        @reason = reason.to_s.strip
        @raw_idempotency_key = idempotency_key
        @rate_version = rate_version
        @at = at.to_time
      end

      def call
        return failure_result(:adjustment_requires_admin, :forbidden) unless authorized?
        return failure_result(:reason_required) if @reason.blank?
        return failure_result(:invalid_credit_quantity) unless @quantity.is_a?(Integer) && !@quantity.zero?

        rescue_invalid_operation do
          ActiveRecord::Base.transaction do
            account = account_for!(CreditAccount.lock.find(@account.id), @organization)
            digest = idempotency_digest("adjustment")
            existing = account.ledger_entries.lock.find_by(entry_type: "adjustment", idempotency_key_digest: digest)
            return replay(existing) if existing
            return failure_result(:insufficient_credits, :conflict) if available(account) + @quantity < 0

            entry = append_entry!(
              account:, rate_version: @rate_version, entry_type: "adjustment",
              quantity: @quantity.abs, available_delta: @quantity,
              reference_type: "Messaging::CreditAdjustment", operation: "adjustment",
              metadata: { "reason" => @reason, "actor_id" => @actor.id.to_s, "at" => @at.iso8601 }
            )
            success(entry)
          end
        end
      rescue Core::BusinessError => exception
        failure(exception)
      end

      private

      def authorized?
        @actor&.super_admin? || @actor&.has_permission?(PERMISSION)
      end

      def available(account)
        account.ledger_entries.sum(:available_delta)
      end

      def replay(existing)
        metadata = existing.metadata
        return success(existing) if metadata["reason"] == @reason && metadata["actor_id"] == @actor.id.to_s &&
          existing.available_delta == @quantity

        failure_result(:credit_idempotency_conflict, :conflict)
      end
    end
  end
end
