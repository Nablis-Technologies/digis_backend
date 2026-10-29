# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module CreditAccounts
    class ReservationRaceTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @organization = organizations_organizations(:three)
        @account = CreditAccount.find_or_create_by!(organization: @organization, channel: "email")
        @rate = CreditRateVersion.find_or_create_by!(organization: @organization, channel: "email", version: 1) do |rate|
          rate.assign_attributes(
            currency: "ETB", unit_price_minor: 1, effective_from: 1.hour.ago,
            status: "active", volume_tiers: [], activated_at: 1.hour.ago,
            idempotency_key_digest: Digest::SHA256.hexdigest("race-rate"),
            request_digest: Digest::SHA256.hexdigest("race-request")
          )
        end
        CreditLedgerEntry.create!(
          credit_account: @account, entry_type: "top_up", quantity: 100, available_delta: 100,
          idempotency_key_digest: Digest::SHA256.hexdigest("race-grant-#{SecureRandom.uuid}"), metadata: {}
        )
        @starting_available = @account.ledger_entries.sum(:available_delta)
        @source_ids = 2.times.map { SecureRandom.uuid }
        @keys = 2.times.map { "reserve-race-#{SecureRandom.uuid}" }
      end

      test "serializes concurrent reservations so one cannot overspend" do
        operations = Prosopite.pause do
          race = run_database_race do |index|
            CreditAccounts::Reserve.call(
              account: CreditAccount.find(@account.id), organization: @organization,
              rate_version: CreditRateVersion.find(@rate.id),
              source_type: "Messaging::CampaignRecipient", source_id: @source_ids.fetch(index),
              quantity: 100, idempotency_key: @keys.fetch(index)
            )
          end
          assert_empty race.errors, race.errors.inspect
          race.results
        end

        assert_equal 1, operations.count(&:success?)
        assert_equal 1, operations.count(&:failure?)
        assert_equal 1, CreditReservation.where(credit_account: @account, source_id: @source_ids).count
        assert_equal @starting_available - 100, @account.reload.ledger_entries.sum(:available_delta)
      end
    end
  end
end
