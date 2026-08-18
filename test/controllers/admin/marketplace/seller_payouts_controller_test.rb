# frozen_string_literal: true

require "test_helper"

module Admin
  module Marketplace
    class SellerPayoutsControllerTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include ::Marketplace::SellerPayoutTestHelpers

      setup do
        setup_seller_payout_context
        @event.update_columns(status: "completed", completed_at: @now - 8.days)
        create_seller_ledger_entry(amount_minor: 10_000)
        @payout = build_seller_payout(idempotency_key: "admin-api-payout").value
      end

      test "platform admin delegates payout dispatch to one command" do
        adapter = ::Marketplace::PayoutProviders::Adapter.new
        ::Marketplace::PayoutProviders::Registry.expects(:fetch).with("telebirr").returns(adapter)
        ::Marketplace::DispatchSellerPayout.expects(:call).with(
          payout: @payout, adapter:
        ).returns(Core::BaseService::Result.success(@payout))

        post "/admin/marketplace/seller_payouts/#{@payout.id}/dispatch",
             params: {}, headers: admin_headers.merge("Idempotency-Key" => "admin-dispatch"), as: :json

        assert_response :success
        data = response.parsed_body.fetch("data")
        assert_equal @payout.id, data.fetch("id")
        %w[provider_reference idempotency_key failure_code].each do |field|
          assert_not data.key?(field), "admin payout response leaked #{field}"
        end
      end

      test "provider lookup failure prevents the payout command from running" do
        ::Marketplace::PayoutProviders::Registry.expects(:fetch).with("telebirr").raises(KeyError)
        ::Marketplace::DispatchSellerPayout.expects(:call).never

        post "/admin/marketplace/seller_payouts/#{@payout.id}/dispatch",
             params: {}, headers: admin_headers.merge("Idempotency-Key" => "admin-provider-error"), as: :json

        assert_response :unprocessable_entity
        assert_equal "seller_payout_provider_unavailable", response.parsed_body.fetch("code")
      end

      test "a regular attendee cannot dispatch a seller payout" do
        post "/admin/marketplace/seller_payouts/#{@payout.id}/dispatch",
             params: {}, headers: user_headers.merge("Idempotency-Key" => "attendee-dispatch"), as: :json

        assert_response :forbidden
      end
    end
  end
end
