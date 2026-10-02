# frozen_string_literal: true

require "test_helper"

module Marketplace
  class SellerPayoutsTest < ActionDispatch::IntegrationTest
    include ResaleFulfillmentTestHelpers

    setup do
      setup_resale_fulfillment_context
      @account = create_seller_payout_account(@owner, "1000000000097", default: true)
      @alternate_account = create_seller_payout_account(@owner, "1000000000099")
    end

    test "seller can immediately withdraw a fulfilled resale to the verified default destination" do
      sale_result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)
      assert_predicate sale_result, :success?, sale_result.error&.message
      sale = sale_result.value
      refute_equal "completed", @event.reload.status
      refute @owner.has_role?("ORGANIZER"), "resale payout access must not require platform-wide organizer RBAC"

      headers = auth_headers(@owner).merge("Idempotency-Key" => "seller-withdraw-#{sale.id}")
      request_params = {
        payout: { currency: "ETB" }
      }

      post "/marketplace/seller/payouts", params: request_params, headers:, as: :json

      assert_response :created
      response_data = response.parsed_body.fetch("data")
      payout = SellerPayout.find(response_data.fetch("id"))
      assert_equal "pending", response_data.fetch("status")
      assert_equal sale.seller_proceeds_minor, response_data.fetch("amount_minor")
      assert_equal @account.id, payout.seller_payout_account_id
      assert_equal @owner.id, payout.seller_user_id
      %w[account_number holder_name account_number_ciphertext idempotency_key provider_reference].each do |field|
        assert_not response_data.key?(field), "payout response leaked #{field}"
      end

      outbox = Core::OutboxEvent.find_by!(event_type: "marketplace.seller_payout.requested", aggregate: payout)
      assert_equal({ "payout_id" => payout.id }, outbox.payload)
      assert_equal 1, Core::AuditLog.where(
        action: "marketplace.seller_payout.requested", auditable_id: payout.id
      ).count
      assert_enqueued_with(job: DispatchSellerPayoutJob, args: [ payout.id ]) do
        Core::Outbox::Dispatch.call(event_id: outbox.id)
      end

      post "/marketplace/seller/payouts", params: request_params, headers:, as: :json
      assert_response :created
      assert_equal payout.id, response.parsed_body.dig("data", "id")
      assert_equal 1, SellerPayout.where(idempotency_key: payout.idempotency_key).count
      assert_equal 1, Core::OutboxEvent.where(aggregate: payout, event_type: "marketplace.seller_payout.requested").count

      post "/marketplace/seller/payouts",
           params: { payout: request_params.fetch(:payout).merge(amount_minor: 1_000) },
           headers:, as: :json
      assert_response :conflict
      assert_equal "idempotency_conflict", response.parsed_body.fetch("code")

      post "/marketplace/seller/payouts",
           params: { payout: request_params.fetch(:payout).merge(seller_payout_account_id: @alternate_account.id) },
           headers:, as: :json
      assert_response :conflict
      assert_equal "idempotency_conflict", response.parsed_body.fetch("code")

      post "/marketplace/seller/payouts",
           params: { payout: request_params.fetch(:payout).merge(currency: "USD") },
           headers:, as: :json
      assert_response :conflict
      assert_equal "idempotency_conflict", response.parsed_body.fetch("code")
    end

    test "seller cannot create a payout without a verified destination" do
      @account.update!(status: "pending_verification", verification_source: nil, verified_at: nil, is_default: false)
      sale_result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)
      assert_predicate sale_result, :success?, sale_result.error&.message

      post "/marketplace/seller/payouts",
           params: { payout: { currency: "ETB" } },
           headers: auth_headers(@owner).merge("Idempotency-Key" => "payout-no-verified-account"), as: :json

      assert_response :unprocessable_entity
      assert_equal "seller_payout_account_required", response.parsed_body.fetch("code")
      assert_empty SellerPayout.where(seller_user: @owner)
      assert_empty Core::OutboxEvent.where(event_type: "marketplace.seller_payout.requested")
    end

    test "seller cannot use another user's verified payout destination" do
      sale_result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)
      assert_predicate sale_result, :success?, sale_result.error&.message
      foreign_account = create_seller_payout_account(@buyer, "1000000000101", default: true)

      post "/marketplace/seller/payouts",
           params: { payout: { currency: "ETB", seller_payout_account_id: foreign_account.id } },
           headers: auth_headers(@owner).merge("Idempotency-Key" => "payout-foreign-account-#{foreign_account.id}"),
           as: :json

      assert_response :unprocessable_entity
      assert_equal "seller_payout_account_required", response.parsed_body.fetch("code")
      assert_empty SellerPayout.where(seller_user: @owner)
    end

    test "seller payout creation requires an idempotency key" do
      sale_result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)
      assert_predicate sale_result, :success?, sale_result.error&.message

      post "/marketplace/seller/payouts",
           params: { payout: { currency: "ETB" } },
           headers: auth_headers(@owner), as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
      assert_empty SellerPayout.where(seller_user: @owner)
    end

    test "seller can list and show their own payout lifecycle" do
      payout = SellerPayout.create!(
        seller_user: @owner,
        seller_payout_account: @account,
        provider: "chapa",
        amount_minor: 100,
        currency: "ETB",
        status: "pending",
        idempotency_key: "seller-payout-view-#{SecureRandom.hex(8)}",
        requested_at: Time.current
      )

      get "/marketplace/seller/payouts", headers: auth_headers(@owner), as: :json

      assert_response :success
      assert_equal [ payout.id ], response.parsed_body.fetch("data").pluck("id")

      get "/marketplace/seller/payouts/#{payout.id}", headers: auth_headers(@owner), as: :json

      assert_response :success
      assert_equal payout.id, response.parsed_body.dig("data", "id")
    end

    test "seller can list payouts with ordering" do
      payout1 = SellerPayout.create!(
        seller_user: @owner,
        seller_payout_account: @account,
        provider: "chapa",
        amount_minor: 100,
        currency: "ETB",
        status: "pending",
        idempotency_key: "seller-payout-order-1-#{SecureRandom.hex(4)}",
        requested_at: 2.hours.ago,
        created_at: 2.hours.ago
      )
      payout2 = SellerPayout.create!(
        seller_user: @owner,
        seller_payout_account: @account,
        provider: "chapa",
        amount_minor: 500,
        currency: "ETB",
        status: "pending",
        idempotency_key: "seller-payout-order-2-#{SecureRandom.hex(4)}",
        requested_at: 1.hour.ago,
        created_at: 1.hour.ago
      )

      get "/marketplace/seller/payouts?order_by=amount_minor&order_direction=asc",
          headers: auth_headers(@owner), as: :json
      assert_response :success
      assert_equal [ payout1.id, payout2.id ], response.parsed_body.fetch("data").pluck("id")

      get "/marketplace/seller/payouts?order_by=amount_minor&order_direction=desc",
          headers: auth_headers(@owner), as: :json
      assert_response :success
      assert_equal [ payout2.id, payout1.id ], response.parsed_body.fetch("data").pluck("id")
    end

    test "seller payout show is scoped to the authenticated seller even for platform admins" do
      payout = SellerPayout.create!(
        seller_user: @owner,
        seller_payout_account: @account,
        provider: "chapa",
        amount_minor: 100,
        currency: "ETB",
        status: "pending",
        idempotency_key: "seller-payout-scope-#{SecureRandom.hex(8)}",
        requested_at: Time.current
      )

      get "/marketplace/seller/payouts/#{payout.id}", headers: auth_headers(core_users(:super_admin)), as: :json

      assert_response :not_found
    end

    private

    def create_seller_payout_account(user, account_number, default: false)
      SellerPayoutAccount.create!(
        user:,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number:,
        account_number_digest: Core::PayoutAccountDigest.call(
          namespace: user.id, account_number:
        ),
        holder_name: "Seller Holder",
        status: "verified",
        verification_source: "test_fixture",
        verified_at: Time.current,
        is_default: default
      )
    end

    def auth_headers(user)
      token = Core::TokenService.issue(Core::TokenService.access_token_payload(user))
      { "Authorization" => "Bearer #{token}" }
    end
  end
end
