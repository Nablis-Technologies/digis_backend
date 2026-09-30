# frozen_string_literal: true

require "test_helper"

module Marketplace
  class SellerPayoutAccountsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Marketplace::SellerPayoutTestHelpers

    class FakePayoutClient
      attr_reader :requested_country

      def initialize(banks:)
        @banks = banks
      end

      def available_banks(country:)
        @requested_country = country
        @banks
      end
    end

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

    test "seller can discover only payout-mapped active destinations" do
      client = FakePayoutClient.new(banks: [
        bank_entry(slug: "cbe", name: "Commercial Bank of Ethiopia"),
        bank_entry(slug: "telebirr", name: "Telebirr", type: "mobile_money"),
        bank_entry(slug: "link", type: "store_value"),
        bank_entry(slug: "closed", active: false)
      ])
      Marketplace::PayoutProviders::Registry.expects(:fetch).with("chapa")
        .returns(Marketplace::PayoutProviders::ChapaAdapter.new(client:))

      get "/marketplace/seller/payout_accounts/destinations", headers: headers_for(@seller), as: :json

      assert_response :success
      assert_equal "ET", client.requested_country
      destinations = response.parsed_body.fetch("data")
      assert_equal [
        {
          "provider" => "chapa", "type" => "bank", "bank_slug" => "cbe",
          "bank_name" => "Commercial Bank of Ethiopia", "country" => "ET", "currency" => "ETB"
        },
        {
          "provider" => "chapa", "type" => "mobile_money", "bank_slug" => "telebirr",
          "bank_name" => "Telebirr", "country" => "ET", "currency" => "ETB"
        }
      ], destinations
    end

    test "seller destination discovery fails safely when Chapa is unavailable" do
      adapter = Marketplace::PayoutProviders::ChapaAdapter.new(client: FakePayoutClient.new(banks: nil))
      Marketplace::PayoutProviders::Registry.expects(:fetch).with("chapa").returns(adapter)

      get "/marketplace/seller/payout_accounts/destinations", headers: headers_for(@seller), as: :json

      assert_response :service_unavailable
      assert_equal "payout_account_provider_unavailable", response.parsed_body.fetch("code")
      assert_not response.parsed_body.key?("data")
    end

    test "seller destination discovery requires authentication" do
      get "/marketplace/seller/payout_accounts/destinations", as: :json

      assert_response :unauthorized
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
      adapter = Marketplace::PayoutProviders::ChapaAdapter.new(
        client: FakePayoutClient.new(banks: [ bank_entry(slug: "cbe") ])
      )
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

    test "seller account creation fails closed when provider discovery is unavailable" do
      adapter = Marketplace::PayoutProviders::ChapaAdapter.new(client: FakePayoutClient.new(banks: nil))
      Marketplace::PayoutProviders::Registry.expects(:fetch).with("chapa").returns(adapter)

      post "/marketplace/seller/payout_accounts",
           params: {
             payout_account: {
               type: "bank", provider: "chapa", bank_slug: "cbe", account_number: "1000000000024",
               holder_name: "Seller Holder"
             }
           },
           headers: headers_for(@seller).merge("Idempotency-Key" => "chapa-account-list-down"), as: :json

      assert_response :service_unavailable
      assert_equal "payout_account_provider_unavailable", response.parsed_body.fetch("code")
      digest = Core::PayoutAccountDigest.call(namespace: @seller.id, account_number: "1000000000024")
      assert_not Marketplace::SellerPayoutAccount.exists?(user: @seller, account_number_digest: digest)
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

    def bank_entry(slug:, name: slug, type: "bank", active: true, enabled: true)
      {
        bank_slug: slug, bank_name: name, type:, is_active: active,
        supported_currencies: { ETB: { countries: { ET: { is_enabled: enabled } } } }
      }
    end

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
