# frozen_string_literal: true

require "test_helper"

module Marketplace
  class SellerPayoutAccountsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Marketplace::SellerPayoutTestHelpers

    setup { setup_seller_payout_context }

    test "seller account index exposes only safe destination metadata" do
      get "/marketplace/seller/payout_accounts", headers: headers_for(@seller), as: :json

      assert_response :success
      data = response.parsed_body.fetch("data").sole
      assert_equal @account.id, data.fetch("id")
      %w[
        account_number account_number_ciphertext account_number_digest holder_name
        account_token account_label_ciphertext holder_name_ciphertext verified_by_id
      ].each do |field|
        assert_not data.key?(field), "seller account response leaked #{field}"
      end
    end

    test "seller account creation delegates direct verification to one command" do
      adapter = Marketplace::PayoutProviders::Adapter.new
      Marketplace::PayoutProviders::Registry.expects(:fetch).with("chapa").returns(adapter)
      Marketplace::VerifyPayoutAccount.expects(:call).with(
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000006",
        account_label: "Primary wallet",
        holder_name: "Seller Holder",
        adapter:,
        idempotency_key: "api-account"
      ).returns(Core::BaseService::Result.success(@account))

      post "/marketplace/seller/payout_accounts",
           params: {
             payout_account: {
               type: "bank", provider: "chapa", bank_slug: "cbe", account_number: "1000000000006",
               account_label: "Primary wallet", holder_name: "Seller Holder"
             }
           },
           headers: headers_for(@seller).merge("Idempotency-Key" => "api-account"), as: :json

      assert_response :created
      assert_equal @account.id, response.parsed_body.dig("data", "id")
      assert_not response.parsed_body.fetch("data").key?("account_token")
    end

    test "configured Chapa creates a pending account when preflight verification is unsupported" do
      adapter = Marketplace::PayoutProviders::Adapter.new
      Marketplace::PayoutProviders::Registry.expects(:fetch).with("chapa").returns(adapter)

      post "/marketplace/seller/payout_accounts",
           params: {
             payout_account: {
               type: "bank", provider: "chapa", bank_slug: "cbe", account_number: "1000000000007",
               holder_name: "Seller Holder"
             }
           },
           headers: headers_for(@seller).merge("Idempotency-Key" => "chapa-account-api"), as: :json

      assert_response :created
      assert_equal "pending_verification", response.parsed_body.dig("data", "status")
    end

    test "seller can select a verified account as the default" do
      post "/marketplace/seller/payout_accounts/#{@account.id}/set_default",
           params: {}, headers: headers_for(@seller).merge("Idempotency-Key" => "seller-default-api"), as: :json

      assert_response :success
      assert_equal true, response.parsed_body.dig("data", "is_default")
    end

    test "seller default selection requires an idempotency key" do
      post "/marketplace/seller/payout_accounts/#{@account.id}/set_default",
           params: {}, headers: headers_for(@seller), as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    private

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
