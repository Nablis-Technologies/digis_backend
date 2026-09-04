# frozen_string_literal: true

module Messaging
  module CreditAccounts
    # Derives safe per-channel balances from immutable ledger evidence.
    class BalanceReport < Core::BaseService
      def initialize(organization:)
        @organization = organization
      end

      def call
        accounts = CreditAccount.where(organization: @organization).order(:channel).to_a
        account_ids = accounts.map(&:id)
        available = CreditLedgerEntry.where(credit_account_id: account_ids)
          .group(:credit_account_id).sum(:available_delta)
        quantities = CreditLedgerEntry.where(credit_account_id: account_ids)
          .group(:credit_account_id, :entry_type).sum(:quantity)
        reserved = CreditReservation.where(credit_account_id: account_ids, status: "reserved")
          .group(:credit_account_id).sum(:quantity)

        success(accounts.map { |account| summary(account, available, quantities, reserved) })
      end

      private

      def summary(account, available, quantities, reserved)
        {
          channel: account.channel,
          available: available.fetch(account.id, 0),
          reserved: reserved.fetch(account.id, 0),
          consumed: quantities.fetch([ account.id, "consume" ], 0),
          released: quantities.fetch([ account.id, "release" ], 0),
          refunded: quantities.fetch([ account.id, "refund" ], 0)
        }
      end
    end
  end
end
