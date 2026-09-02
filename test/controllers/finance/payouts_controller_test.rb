# frozen_string_literal: true

require "test_helper"

module Finance
  class PayoutsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Finance::PayoutTestHelpers

    setup do
      setup_payout_context
      @event.update_columns(status: "completed", completed_at: @now - 8.days)
      create_payout_entry(type: "sale", amount_minor: 10_000)
      @payout = build_payout(idempotency_key: "controller-payout").value
      Organizations::Membership.create!(
        user: core_users(:core_admin), organization: @organization, role: "owner", status: "active"
      )
    end

    test "organizer sees own payout and ledger report without provider treasury fields" do
      get "/finance/organizations/#{@organization.id}/payouts", headers: owner_headers, as: :json

      assert_response :success
      payout = response.parsed_body.fetch("data").sole
      assert_equal @payout.id, payout.fetch("id")
      assert_equal 10_000, payout.fetch("amount_minor")
      assert_equal "ETB", payout.fetch("currency")
      assert_equal @payout.payout_account.id, payout.dig("payout_account", "id")
      assert_equal "verified", payout.dig("payout_account", "status")
      assert_nil payout.fetch("status_reason_code")
      %w[provider provider_reference idempotency_key failure_code].each do |key|
        assert_not payout.key?(key), "organizer response leaked #{key}"
      end

      get "/finance/organizations/#{@organization.id}/ledger_entries", headers: owner_headers, as: :json

      assert_response :success
      entry = response.parsed_body.fetch("data").sole
      assert_equal 10_000, entry.fetch("amount_minor")
      assert_equal "ETB", entry.fetch("currency")
      assert_equal @event.title, entry.dig("event", "title")
      assert_not entry.key?("idempotency_key")
    end

    test "organizer payout and ledger lists include bounded pagination" do
      create_payout_entry(type: "platform_fee", amount_minor: -100)

      get "/finance/organizations/#{@organization.id}/payouts?page=1&per_page=1",
          headers: owner_headers, as: :json
      assert_response :success
      assert_equal 1, response.parsed_body.fetch("data").length
      assert_equal 1, response.parsed_body.dig("pagination", "per_page")
      assert_equal 1, response.parsed_body.dig("pagination", "total_count")

      get "/finance/organizations/#{@organization.id}/ledger_entries?page=1&per_page=1",
          headers: owner_headers, as: :json
      assert_response :success
      assert_equal 1, response.parsed_body.fetch("data").length
      assert_equal 2, response.parsed_body.dig("pagination", "total_count")
    end

    test "organizer ledger reports honor requested ordering" do
      create_payout_entry(type: "platform_fee", amount_minor: -100, available_at: @now - 29.days)

      get "/finance/organizations/#{@organization.id}/ledger_entries?order_by=amount_minor&order_direction=asc",
          headers: owner_headers, as: :json

      assert_response :success
      assert_equal [ -100, 10_000 ], response.parsed_body.fetch("data").pluck("amount_minor")
    end

    test "organizer can request a payout through exactly one command" do
      payout = Finance::Payout.new(
        organization: @organization, currency: "ETB", status: "pending", amount_minor: 5_000,
        provider: "chapa", provider_reference: "provider-reference",
        failure_code: "insufficient_balance", idempotency_key: "requested-payout", requested_at: Time.current
      )
      Finance::BuildPayout.expects(:call).with(
        organization: @organization, currency: "ETB", amount_minor: 5_000,
        idempotency_key: "requested-payout"
      ).returns(Core::BaseService::Result.success(payout))

      post "/finance/organizations/#{@organization.id}/payouts",
           params: { payout: { currency: "ETB", amount_minor: 5_000 } },
           headers: owner_headers.merge("Idempotency-Key" => "requested-payout"), as: :json

      assert_response :created
      assert_equal 5_000, response.parsed_body.dig("data", "amount_minor")
      data = response.parsed_body.fetch("data")
      %w[provider provider_reference idempotency_key failure_code].each do |key|
        assert_not data.key?(key), "request response leaked #{key}"
      end
      assert_equal "provider_liquidity", data.fetch("status_reason_code")
    end

    test "attendee cannot access organizer finance reports" do
      get "/finance/organizations/#{@organization.id}/balance", headers: user_headers, as: :json

      assert_response :forbidden
    end

    test "organizer balance is derived from the ledger and reserved payout allocations" do
      get "/finance/organizations/#{@organization.id}/balance", headers: owner_headers, as: :json

      assert_response :success
      assert_equal [ {
        "currency" => "ETB", "ledger_total_minor" => 10_000,
        "reserved_minor" => 10_000, "available_minor" => 0,
        "pending_maturity_minor" => 0, "next_available_at" => nil
      } ], response.parsed_body.fetch("data")
    end

    test "only a platform finance admin can change reserve policy" do
      Finance::UpdateProviderReservePolicy.expects(:call).with(
        provider: "chapa", currency: "ETB", target_minor: 2_000,
        actor: core_users(:super_admin), idempotency_key: "reserve-update"
      ).returns(Core::BaseService::Result.success(ProviderReservePolicy.new(
        provider: "chapa", currency: "ETB", target_minor: 2_000
      )))

      put "/finance/reserve_policies/chapa/ETB",
          params: { target_minor: 2_000 },
          headers: admin_headers.merge("Idempotency-Key" => "reserve-update"), as: :json

      assert_response :success

      put "/finance/reserve_policies/chapa/ETB",
          params: { target_minor: 2_000 },
          headers: user_headers.merge("Idempotency-Key" => "reserve-forbidden"), as: :json

      assert_response :forbidden
    end

    test "platform dispatch delegates to exactly one command" do
      adapter = Finance::PayoutProviders::Adapter.new
      Finance::PayoutProviders::Registry.expects(:fetch).with("chapa").returns(adapter)
      Finance::DispatchPayout.expects(:call).with(
        payout: @payout, adapter:, treasury_approval: nil
      ).returns(Core::BaseService::Result.success(@payout))

      post "/finance/organizations/#{@organization.id}/payouts/#{@payout.id}/dispatch",
           params: { provider: "chapa" }, headers: admin_headers.merge("Idempotency-Key" => "dispatch"), as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      %w[provider provider_reference idempotency_key failure_code].each do |key|
        assert_not data.key?(key), "dispatch response leaked #{key}"
      end
    end

    test "platform reconciliation delegates to exactly one command" do
      adapter = Finance::PayoutProviders::Adapter.new
      Finance::PayoutProviders::Registry.expects(:fetch).with("chapa").returns(adapter)
      Finance::ReconcilePayout.expects(:call).with(
        payout: @payout, adapter:
      ).returns(Core::BaseService::Result.success(@payout))

      post "/finance/organizations/#{@organization.id}/payouts/#{@payout.id}/reconcile",
           params: { provider: "chapa" }, headers: admin_headers.merge("Idempotency-Key" => "reconcile"), as: :json

      assert_response :success
    end

    test "platform no-balance approval delegates to exactly one command" do
      Finance::ApprovePayoutWithoutBalanceApi.expects(:call).with(
        payout: @payout, actor: core_users(:super_admin), idempotency_key: "approval", reason: "manual review"
      ).returns(Core::BaseService::Result.success(@payout))

      post "/finance/payouts/#{@payout.id}/approve_no_balance_api",
           params: { reason: "manual review" }, headers: admin_headers.merge("Idempotency-Key" => "approval"), as: :json

      assert_response :success
    end

    test "mutating payout endpoints require an idempotency key" do
      post "/finance/organizations/#{@organization.id}/payouts",
           params: { payout: { currency: "ETB" } }, headers: owner_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end
  end
end
