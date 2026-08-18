# frozen_string_literal: true

require "test_helper"

module Marketplace
  class SellerPayoutJobsTest < ActiveJob::TestCase
    include ActiveJob::TestHelper
    include SellerPayoutTestHelpers

    setup do
      setup_seller_payout_context
      create_seller_ledger_entry(amount_minor: 10_000)
    end

    test "maturity fans out one deterministic build per verified seller account" do
      assert_enqueued_with(
        job: BuildSellerPayoutJob,
        args: [ @seller.id, @account.id, @event.id, "ETB", "marketplace-seller-payout-matured-#{@event.id}-#{@seller.id}-ETB" ]
      ) do
        MatureSellerProceedsJob.perform_now(@event.id, at: @now)
      end
    end

    test "a successful build enqueues dispatch after the payout intent commits" do
      assert_enqueued_with(job: DispatchSellerPayoutJob) do
        BuildSellerPayoutJob.perform_now(
          @seller.id,
          @account.id,
          @event.id,
          "ETB",
          "marketplace-job-payout-#{SecureRandom.hex(8)}"
        )
      end
    end
  end
end
