# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module CreditAccounts
    class LifecycleTest < ActiveSupport::TestCase
      setup do
        @organization = organizations_organizations(:one)
        @account = Messaging::CreditAccount.create!(organization: @organization, channel: "sms")
        @rate = Messaging::CreditRateVersion.create!(
          organization: @organization, channel: "sms", version: 1, currency: "ETB", unit_price_minor: 50,
          volume_tiers: [], effective_from: 1.hour.ago, status: "active",
          idempotency_key_digest: Digest::SHA256.hexdigest("rate"),
          request_digest: Digest::SHA256.hexdigest("rate-request"),
          activated_at: 1.hour.ago
        )
        grant_credits(100)
      end

      test "reserves credits atomically and replays the same key" do
        source_id = SecureRandom.uuid
        operation = -> {
          Reserve.call(
            account: @account, organization: @organization, rate_version: @rate,
            source_type: "Messaging::CampaignRecipient", source_id:, quantity: 30,
            idempotency_key: "reserve-1"
          )
        }

        assert_idempotent(operation, counter: -> { Messaging::CreditReservation.count })
        reservation = operation.call.value
        assert_equal "reserved", reservation.status
        assert_equal(-30, reservation.credit_account.ledger_entries.where(entry_type: "reserve").sum(:available_delta))
      end

      test "rejects a reservation larger than the available balance" do
        result = Reserve.call(
          account: @account, organization: @organization, rate_version: @rate,
          source_type: "Messaging::CampaignRecipient", source_id: SecureRandom.uuid,
          quantity: 101, idempotency_key: "reserve-too-large"
        )

        assert_predicate result, :failure?
        assert_equal "insufficient_credits", result.error.code
      end

      test "accepts a reservation backed by a non-ETB rate" do
        usd_rate = Messaging::CreditRateVersion.create!(
          organization: @organization, channel: "sms", version: 2, currency: "USD", unit_price_minor: 50,
          volume_tiers: [], effective_from: 1.hour.ago, status: "active",
          idempotency_key_digest: Digest::SHA256.hexdigest("usd-rate"),
          request_digest: Digest::SHA256.hexdigest("usd-rate-request"), activated_at: 1.hour.ago
        )

        result = Reserve.call(
          account: @account, organization: @organization, rate_version: usd_rate,
          source_type: "Messaging::CampaignRecipient", source_id: SecureRandom.uuid,
          quantity: 1, idempotency_key: "reserve-usd"
        )

        assert_predicate result, :success?, result.error&.message
      end

      test "releases, consumes, and refunds a reservation exactly once" do
        reservation = Reserve.call(
          account: @account, organization: @organization, rate_version: @rate,
          source_type: "Messaging::CampaignRecipient", source_id: SecureRandom.uuid,
          quantity: 10, idempotency_key: "reserve-lifecycle"
        ).value

        released = Release.call(reservation:, idempotency_key: "release-1", reason: "suppressed")
        assert_predicate released, :success?, released.error&.message
        assert_equal "released", released.value.status

        consumed_reservation = Reserve.call(
          account: @account, organization: @organization, rate_version: @rate,
          source_type: "Messaging::CampaignRecipient", source_id: SecureRandom.uuid,
          quantity: 10, idempotency_key: "reserve-consume"
        ).value
        consumed = Consume.call(reservation: consumed_reservation, idempotency_key: "consume-1")
        assert_predicate consumed, :success?, consumed.error&.message
        assert_equal "consumed", consumed.value.status

        refunded_reservation = Reserve.call(
          account: @account, organization: @organization, rate_version: @rate,
          source_type: "Messaging::CampaignRecipient", source_id: SecureRandom.uuid,
          quantity: 10, idempotency_key: "reserve-refund"
        ).value
        refunded = Refund.call(reservation: refunded_reservation, idempotency_key: "refund-1", reason: "provider_failed")
        assert_predicate refunded, :success?, refunded.error&.message
        assert_equal "refunded", refunded.value.status
      end

      test "returns typed failures when lifecycle idempotency keys are malformed" do
        reservation = Reserve.call(
          account: @account, organization: @organization, rate_version: @rate,
          source_type: "Messaging::CampaignRecipient", source_id: SecureRandom.uuid,
          quantity: 1, idempotency_key: "malformed-key-reserve"
        ).value

        results = [
          Consume.call(reservation:, idempotency_key: nil),
          Release.call(reservation:, idempotency_key: nil, reason: "suppressed"),
          Refund.call(reservation:, idempotency_key: nil, reason: "provider_failed"),
          Expire.call(reservation:, idempotency_key: nil)
        ]

        assert results.all?(&:failure?)
        assert results.all? { |result| result.error.code == "invalid_idempotency_key" }
        assert_equal "reserved", reservation.reload.status
      end


      private


      def grant_credits(quantity)
        Messaging::CreditLedgerEntry.create!(
          credit_account: @account,
          entry_type: "top_up",
          quantity:,
          available_delta: quantity,
          idempotency_key_digest: Digest::SHA256.hexdigest("grant-#{SecureRandom.uuid}"),
          metadata: {}
        )
      end
    end
  end
end
