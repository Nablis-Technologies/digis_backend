# frozen_string_literal: true

require "test_helper"

module Orders
  class ExpireGiftPurchasesJobTest < ActiveJob::TestCase
    include Orders::GiftPurchaseTestHelpers

    setup do
      setup_gift_purchase_context
    end

    test "processes due gifts through the idempotent expiry command" do
      ExpireGiftPurchasesJob.perform_now(now: @gift_purchase.expires_at, limit: 10)

      assert_equal "expired", @gift_purchase.reload.status
      assert_equal "expired", @gift_registration.reload.status
    end
  end
end
