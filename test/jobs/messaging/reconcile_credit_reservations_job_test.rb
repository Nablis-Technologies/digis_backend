# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class ReconcileCreditReservationsJobTest < ActiveJob::TestCase
    setup do
      CreditReservation.delete_all
      @organization = organizations_organizations(:one)
      @account = CreditAccount.create!(organization: @organization, channel: "sms")
      @rate = CreditRateVersion.create!(
        channel: "sms", version: 1, currency: "ETB", unit_price_minor: 1,
        effective_from: 1.hour.ago, status: "active", volume_tiers: [],
        idempotency_key_digest: Digest::SHA256.hexdigest("job-rate"),
        request_digest: Digest::SHA256.hexdigest("job-rate-request"), activated_at: 1.hour.ago
      )
      CreditLedgerEntry.create!(
        credit_account: @account, rate_version: @rate, entry_type: "top_up", quantity: 10,
        available_delta: 10, idempotency_key_digest: Digest::SHA256.hexdigest("job-grant"), metadata: {}
      )
    end

    test "expires stale reservations in bounded pages" do
      @reservation_ids = Prosopite.pause do
        ids = []
        2.times do |index|
          reservation = CreditAccounts::Reserve.call(
            account: @account, organization: @organization, rate_version: @rate,
            source_type: "Messaging::CampaignRecipient", source_id: SecureRandom.uuid,
            quantity: 1, idempotency_key: "job-reserve-#{index}"
          ).value
          reservation.update_columns(reserved_at: 2.days.ago)
          ids << reservation.id
        end
        ids
      end

      Prosopite.pause { ReconcileCreditReservationsJob.perform_now(limit: 1, now: Time.current) }

      assert_equal 1, CreditReservation.where(id: @reservation_ids, status: "expired").count
      assert_equal 1, CreditReservation.where(id: @reservation_ids, status: "reserved").count
      assert_enqueued_with(job: ReconcileCreditReservationsJob) do
        Prosopite.pause { ReconcileCreditReservationsJob.perform_now(limit: 1, now: Time.current) }
      end
    end
  end
end
