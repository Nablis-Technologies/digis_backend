# frozen_string_literal: true

module Messaging
  module CreditAccounts
    # Holds channel credits for one future campaign source identity.
    class Reserve < Core::BaseService
      include CommandSupport

      def initialize(account:, organization:, rate_version:, source_type:, source_id:, quantity:,
        idempotency_key:, at: Time.current)
        @account = account
        @organization = organization
        @rate_version = rate_version
        @source_type = source_type.to_s.strip.presence
        @source_id = source_id
        @quantity = quantity
        @raw_idempotency_key = idempotency_key
        @at = at.to_time
      end

      def call
        rescue_invalid_operation do
          return failure_result(:invalid_credit_quantity) unless valid_request?

          ActiveRecord::Base.transaction do
            account = account_for!(CreditAccount.lock.find(@account.id), @organization)
            existing = CreditReservation.lock.find_by(
              credit_account_id: account.id,
              idempotency_key_digest: idempotency_key.digest
            )
            return replay(existing) if existing
            return failure_result(:insufficient_credits, :conflict) if available(account) < @quantity

            reservation = CreditReservation.create!(
              credit_account: account,
              organization: @organization,
              rate_version: @rate_version,
              source_type: @source_type,
              source_id: @source_id,
              channel: account.channel,
              quantity: @quantity,
              status: "reserved",
              idempotency_key_digest: idempotency_key.digest,
              reserved_at: @at
            )
            append_entry!(
              account:, rate_version: @rate_version, entry_type: "reserve",
              quantity: @quantity, available_delta: -@quantity,
              reference_type: "Messaging::CreditReservation", reference_id: reservation.id,
              operation: "reserve:#{reservation.id}", metadata: { "source_type" => @source_type }
            )
            success(reservation)
          end
        end
      rescue Core::BusinessError => exception
        failure(exception)
      end

    private

    def valid_request?
      # Reservations are limited to campaign aggregates and recipients. Keeping
      # this source and rate/account scope check here prevents other callers
      # from spending an organization's credits through a generic polymorphic ID.
      @organization.is_a?(Organizations::Organization) &&
        @rate_version.is_a?(CreditRateVersion) &&
        @quantity.is_a?(Integer) && @quantity.positive? &&
        @source_type.in?(%w[Messaging::Campaign Messaging::CampaignRecipient]) && @source_id.present? &&
        @rate_version.channel == @account.channel &&
        (@rate_version.organization_id.nil? || @rate_version.organization_id == @organization.id)
      end

      def available(account)
        account.ledger_entries.sum(:available_delta)
      end

      def replay(existing)
        return success(existing) if existing.channel == @account.channel &&
          existing.quantity == @quantity && existing.source_type == @source_type &&
          existing.source_id == @source_id && existing.rate_version_id == @rate_version.id

        failure_result(:credit_idempotency_conflict, :conflict)
      end
    end
  end
end
