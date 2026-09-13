# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ConcurrentSellerPayoutAccountTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      @seller = core_users(:attendee)
      @now = Time.utc(2026, 8, 13, 12, 0, 0)
    end

    teardown do
      account_ids = SellerPayoutAccount.where(user_id: @seller.id).pluck(:id)
      Core::AuditLog.where(
        auditable_type: SellerPayoutAccount.name, auditable_id: account_ids
      ).delete_all
      SellerPayoutAccount.where(id: account_ids).delete_all
    end

    test "same-key concurrent registrations with different payloads return one typed conflict" do
      race = run_database_race do |index|
        VerifyPayoutAccount.call(
          user: Core::User.find(@seller.id),
          type: "bank",
          provider: "chapa",
          bank_slug: "cbe",
          account_number: "100000000002#{index + 1}",
          holder_name: "Concurrent Seller #{index}",
          adapter: Marketplace::PayoutProviders::Adapter.new,
          idempotency_key: "concurrent-seller-account",
          at: @now
        )
      end

      assert_empty race.errors, race.errors.inspect
      assert_equal 1, race.results.count(&:success?), race.results.inspect
      assert_equal 1, race.results.count(&:failure?), race.results.inspect
      assert_equal "idempotency_conflict", race.results.find(&:failure?).error.code
      assert_equal 1, SellerPayoutAccount.where(user_id: @seller.id).count
    end
  end
end
