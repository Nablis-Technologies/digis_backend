# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ConcurrentSellerPayoutTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include SellerPayoutTestHelpers

    setup do
      setup_seller_payout_context
      @entry = create_seller_ledger_entry(amount_minor: 10_000)
    end

    teardown do
      allocation_ids = SellerPayoutAllocation.joins(:payout)
        .where(marketplace_seller_payouts: { seller_user_id: @seller.id })
        .pluck(:id)
      SellerPayoutAllocation.where(id: allocation_ids).delete_all
      SellerPayout.where(seller_user_id: @seller.id).delete_all
      connection = Marketplace::ApplicationRecord.connection
      connection.execute(
        "ALTER TABLE marketplace_seller_ledger_entries DISABLE TRIGGER " \
        "trg_marketplace_seller_ledger_entry_immutable"
      )
      begin
        SellerLedgerEntry.where(id: @entry.id).delete_all
      ensure
        connection.execute(
          "ALTER TABLE marketplace_seller_ledger_entries ENABLE TRIGGER " \
          "trg_marketplace_seller_ledger_entry_immutable"
        )
      end
      SellerPayoutAccount.where(id: @account.id).delete_all
    end

    test "concurrent builders reserve seller proceeds at most once" do
      ready = Queue.new
      start = Queue.new
      threads = 2.times.map do |index|
        Thread.new do
          ready << true
          start.pop
          Marketplace::ApplicationRecord.connection_pool.with_connection do
            Marketplace::BuildSellerPayout.call(
              seller: Core::User.find(@seller.id),
              account: Marketplace::SellerPayoutAccount.find(@account.id),
              event: Events::Event.find(@event.id),
              currency: "ETB",
              idempotency_key: "concurrent-seller-payout-#{index}",
              cutoff_at: @now,
              at: @now
            )
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)

      assert_equal 1, results.count(&:success?), results.map { |r| [ r.success?, r.error&.code ] }.inspect
      assert_equal 1, results.count(&:failure?), results.map { |r| [ r.success?, r.error&.code ] }.inspect
      assert_equal 1, SellerPayout.where(seller_user_id: @seller.id).count
      assert_equal 1, SellerPayoutAllocation.joins(:payout)
        .where(marketplace_seller_payouts: { seller_user_id: @seller.id }).count
    ensure
      threads&.each(&:join)
    end
  end
end
