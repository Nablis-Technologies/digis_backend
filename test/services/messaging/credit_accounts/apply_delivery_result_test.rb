# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module CreditAccounts
    class ApplyDeliveryResultTest < ActiveSupport::TestCase
      setup do
        @organization = organizations_organizations(:one)
        @account = Messaging::CreditAccount.create!(organization: @organization, channel: "sms")
        @rate = Messaging::CreditRateVersion.create!(
          channel: "sms", version: 1, currency: "ETB", unit_price_minor: 50,
          effective_from: 1.hour.ago, status: "active", volume_tiers: [],
          idempotency_key_digest: Digest::SHA256.hexdigest("delivery-rate"),
          request_digest: Digest::SHA256.hexdigest("delivery-rate-request"), activated_at: 1.hour.ago
        )
        Messaging::CreditLedgerEntry.create!(
          credit_account: @account, entry_type: "top_up", quantity: 20, available_delta: 20,
          idempotency_key_digest: Digest::SHA256.hexdigest("delivery-grant"), metadata: {}
        )
        @reservation = Reserve.call(
          account: @account, organization: @organization, rate_version: @rate,
          source_type: "Messaging::CampaignRecipient", source_id: SecureRandom.uuid,
          quantity: 1, idempotency_key: "delivery-reserve"
        ).value
      end

      test "suppression releases credit without a provider result" do
        result = ApplyDeliveryResult.call(
          reservation: @reservation, result: :suppressed, idempotency_key: "delivery-suppressed"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "released", result.value.status
        assert_equal 20, @account.reload.ledger_entries.sum(:available_delta)
      end

      test "success consumes exactly once and retryable failures stay reserved" do
        delivered = Providers::DeliveryResult.delivered(provider: "fake")
        operation = -> {
          ApplyDeliveryResult.call(
            reservation: @reservation, result: delivered, idempotency_key: "delivery-success"
          )
        }

        assert_idempotent(operation, counter: -> { Messaging::CreditLedgerEntry.where(entry_type: "consume").count })
        assert_equal "consumed", @reservation.reload.status

        second = Reserve.call(
          account: @account, organization: @organization, rate_version: @rate,
          source_type: "Messaging::CampaignRecipient", source_id: SecureRandom.uuid,
          quantity: 1, idempotency_key: "delivery-retry-reserve"
        ).value
        retryable = ApplyDeliveryResult.call(
          reservation: second, result: Providers::DeliveryResult.retryable(provider: "fake", failure_code: "timeout"),
          idempotency_key: "delivery-retry"
        )
        assert_predicate retryable, :success?, retryable.error&.message
        assert_equal "reserved", second.reload.status
      end

      test "permanent failures refund exactly once" do
        result = ApplyDeliveryResult.call(
          reservation: @reservation,
          result: Providers::DeliveryResult.failed(provider: "fake", failure_code: "rejected"),
          idempotency_key: "delivery-failed"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "refunded", result.value.status
        assert_equal 20, @account.reload.ledger_entries.sum(:available_delta)
      end
    end
  end
end
