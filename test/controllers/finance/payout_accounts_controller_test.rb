# frozen_string_literal: true

require "test_helper"

module Finance
  class PayoutAccountsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @organization = Organizations::Organization.create!(
        name: "Payout API Organization #{SecureRandom.hex(4)}",
        slug: "payout-api-organization-#{SecureRandom.hex(4)}",
        organizer_type: "company",
        category: "music"
      )
      Organizations::Membership.create!(
        user: core_users(:core_admin), organization: @organization,
        role: "owner", status: "active"
      )
      @account = create_account
    end

    test "lists only safe payout-account metadata" do
      get "/finance/organizations/#{@organization.id}/payout_accounts",
          headers: owner_headers, as: :json

      assert_response :success
      data = response.parsed_body.fetch("data").sole
      assert_equal @account.id, data.fetch("id")
      %w[account_number account_number_ciphertext account_number_digest
         account_name account_name_ciphertext].each do |field|
        assert_not data.key?(field), "response leaked #{field}"
      end
    end

    test "paginates payout-account metadata when requested" do
      create_account(number: "1000000000002", is_default: false)

      get "/finance/organizations/#{@organization.id}/payout_accounts?page=2&per_page=1",
          headers: owner_headers, as: :json

      assert_response :success
      assert_equal 2, response.parsed_body.dig("pagination", "total_count")
      assert_equal 2, response.parsed_body.dig("pagination", "current_page")
    end

    test "creates a payout account through one registration command" do
      adapter = Finance::PayoutProviders::Adapter.new
      Finance::PayoutProviders::Registry.expects(:fetch).with("chapa").returns(adapter)
      Finance::PayoutAccounts::Register.expects(:call).with(
        organization: @organization,
        type: "bank",
        provider: "chapa",
        bank_code: 128,
        account_number: "1000000000002",
        account_name: "Organizer Account",
        account_label: "Primary",
        actor: core_users(:core_admin),
        adapter:,
        idempotency_key: "account-create"
      ).returns(Core::BaseService::Result.success(@account))

      post "/finance/organizations/#{@organization.id}/payout_accounts",
           params: {
             payout_account: {
               type: "bank", provider: "chapa", bank_code: 128,
               account_number: "1000000000002", account_name: "Organizer Account",
               account_label: "Primary"
             }
           },
           headers: owner_headers.merge("Idempotency-Key" => "account-create"), as: :json

      assert_response :created
      assert_equal @account.id, response.parsed_body.dig("data", "id")
    end

    test "verification delegates to one audited command" do
      Finance::PayoutAccounts::Verify.expects(:call).with(
        account: @account,
        actor: core_users(:super_admin),
        reason: "Confirmed",
        evidence_reference: "case-1",
        idempotency_key: "account-verify"
      ).returns(Core::BaseService::Result.success(@account))

      post "/finance/organizations/#{@organization.id}/payout_accounts/#{@account.id}/verify",
           params: { reason: "Confirmed", evidence_reference: "case-1" },
           headers: admin_headers.merge("Idempotency-Key" => "account-verify"), as: :json

      assert_response :success
      assert_equal @account.id, response.parsed_body.dig("data", "id")
    end

    test "default selection delegates to one command" do
      Finance::PayoutAccounts::SetDefault.expects(:call).with(
        account: @account, actor: core_users(:core_admin), idempotency_key: "account-default"
      ).returns(Core::BaseService::Result.success(@account))

      post "/finance/organizations/#{@organization.id}/payout_accounts/#{@account.id}/set_default",
           headers: owner_headers.merge("Idempotency-Key" => "account-default"), as: :json

      assert_response :success
      assert_equal @account.id, response.parsed_body.dig("data", "id")
    end

    test "suspension and closure delegate to their audited commands" do
      Finance::PayoutAccounts::Suspend.expects(:call).with(
        account: @account, actor: core_users(:super_admin),
        reason: "Review", idempotency_key: "account-suspend"
      ).returns(Core::BaseService::Result.success(@account))
      Finance::PayoutAccounts::Close.expects(:call).with(
        account: @account, actor: core_users(:super_admin),
        reason: "Replacement", idempotency_key: "account-close"
      ).returns(Core::BaseService::Result.success(@account))

      post "/finance/organizations/#{@organization.id}/payout_accounts/#{@account.id}/suspend",
           params: { reason: "Review" },
           headers: admin_headers.merge("Idempotency-Key" => "account-suspend"), as: :json
      assert_response :success

      post "/finance/organizations/#{@organization.id}/payout_accounts/#{@account.id}/close",
           params: { reason: "Replacement" },
           headers: admin_headers.merge("Idempotency-Key" => "account-close"), as: :json
      assert_response :success
    end

    test "mutating account endpoints require an idempotency key" do
      post "/finance/organizations/#{@organization.id}/payout_accounts",
           params: { payout_account: { type: "bank", provider: "chapa", bank_code: 128,
                                        account_number: "1000000000002" } },
           headers: owner_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    private

    def create_account(number: "1000000000001", is_default: true)
      PayoutAccount.create!(
        organization: @organization,
        type: "bank",
        provider: "chapa",
        bank_code: 128,
        account_number: number,
        account_name: "Organizer Account",
        account_label: "Primary",
        account_number_digest: Core::KeyedDigest.digest(
          namespace: @organization.id, value: number
        ),
        status: "verified",
        verification_source: "test_fixture",
        verified_at: Time.current,
        is_default:
      )
    end
  end
end
