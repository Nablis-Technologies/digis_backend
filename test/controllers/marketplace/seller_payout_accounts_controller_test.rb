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
      %w[account_token account_label_ciphertext holder_name_ciphertext].each do |field|
        assert_not data.key?(field), "seller account response leaked #{field}"
      end
    end

    test "seller account creation delegates verification to one command" do
      adapter = Marketplace::PayoutProviders::Adapter.new
      Marketplace::PayoutProviders::Registry.expects(:fetch).with("telebirr").returns(adapter)
      Marketplace::VerifyPayoutAccount.expects(:call).with(
        user: @seller,
        type: "mobile_money",
        provider: "telebirr",
        account_details: { "phone" => "251911000003" },
        account_label: "Primary wallet",
        holder_name: "Seller Holder",
        adapter:,
        idempotency_key: "api-account"
      ).returns(Core::BaseService::Result.success(@account))

      post "/marketplace/seller/payout_accounts",
           params: {
             payout_account: {
               type: "mobile_money", provider: "telebirr", account_details: { phone: "251911000003" },
               account_label: "Primary wallet", holder_name: "Seller Holder"
             }
           },
           headers: headers_for(@seller).merge("Idempotency-Key" => "api-account"), as: :json

      assert_response :created
      assert_equal @account.id, response.parsed_body.dig("data", "id")
      assert_not response.parsed_body.fetch("data").key?("account_token")
    end

    test "configured Chapa fails closed instead of reporting an empty provider registry" do
      with_env(
        "CHAPA_ENABLED" => "true",
        "CHAPA_PAYOUT_ENABLED" => "true",
        "CHAPA_MODE" => "test",
        "CHAPA_SECRET_KEY" => "CHASECK_TEST-marketplace-api-test",
        "RENDER_PREVIEW" => "true"
      ) do
        Marketplace::PayoutProviders::Registration.call(env: ENV)

        post "/marketplace/seller/payout_accounts",
             params: {
               payout_account: {
                 type: "bank", provider: "chapa", account_details: { account_number: "1000000000001" },
                 holder_name: "Seller Holder"
               }
             },
             headers: headers_for(@seller).merge("Idempotency-Key" => "chapa-account-api"), as: :json
      end

      assert_response :unprocessable_entity
      assert_equal "payout_account_provider_unavailable", response.parsed_body.fetch("code")
    end

    private

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end

    def with_env(values)
      original = values.to_h { |key, _value| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end
end
