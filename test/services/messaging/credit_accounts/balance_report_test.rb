# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module CreditAccounts
    class BalanceReportTest < ActiveSupport::TestCase
      test "reports separate channel balances from ledger and reservations" do
        organization = organizations_organizations(:one)
        sms = Messaging::CreditAccount.create!(organization:, channel: "sms")
        email = Messaging::CreditAccount.create!(organization:, channel: "email")
        [ [ sms, 10, "balance-sms" ], [ email, 20, "balance-email" ] ].each do |account, quantity, key|
          Messaging::CreditLedgerEntry.create!(
            credit_account: account, entry_type: "top_up", quantity:, available_delta: quantity,
            idempotency_key_digest: Digest::SHA256.hexdigest(key), metadata: {}
          )
        end

        rate = Messaging::CreditRateVersion.create!(
          channel: "sms", version: 1, currency: "ETB", unit_price_minor: 1,
          effective_from: 1.hour.ago, status: "active", volume_tiers: [],
          idempotency_key_digest: Digest::SHA256.hexdigest("balance-rate"),
          request_digest: Digest::SHA256.hexdigest("balance-rate-request"), activated_at: 1.hour.ago
        )
        reservation = Reserve.call(
          account: sms, organization:, rate_version: rate,
          source_type: "Messaging::CampaignRecipient", source_id: SecureRandom.uuid,
          quantity: 3, idempotency_key: "balance-reserve"
        ).value

        result = BalanceReport.call(organization:)

        assert_predicate result, :success?, result.error&.message
        assert_equal(
          { channel: "email", available: 20, reserved: 0, consumed: 0, released: 0, refunded: 0 },
          result.value.find { |summary| summary[:channel] == "email" }
        )
        assert_equal(
          { channel: "sms", available: 7, reserved: 3, consumed: 0, released: 0, refunded: 0 },
          result.value.find { |summary| summary[:channel] == "sms" }
        )
        assert_equal "reserved", reservation.status
      end
    end
  end
end
