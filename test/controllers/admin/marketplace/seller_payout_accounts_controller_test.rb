# frozen_string_literal: true

require "test_helper"

module Admin
  module Marketplace
    class SellerPayoutAccountsControllerTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include ::Marketplace::SellerPayoutTestHelpers

      setup do
        setup_seller_payout_context
        @pending = create_payout_account(account_number: "1000000000012")
      end

      test "admin can list safe seller payout accounts" do
        get "/admin/marketplace/seller_payout_accounts", headers: admin_headers, as: :json

        assert_response :success
        data = response.parsed_body.fetch("data")
        assert data.any? { |account| account.fetch("id") == @pending.id }
        data.each do |account|
          %w[account_number account_number_ciphertext account_number_digest holder_name holder_name_ciphertext
             account_token verified_by_id].each do |field|
            assert_not account.key?(field), "admin response leaked #{field}"
          end
        end
      end

      test "admin can manually verify a pending seller account" do
        post "/admin/marketplace/seller_payout_accounts/#{@pending.id}/verify",
             params: {
               reason: "Verified against seller-provided bank evidence",
               evidence_reference: "case-2026-09-10-006"
             }, headers: admin_headers.merge("Idempotency-Key" => "admin-seller-verify"), as: :json

        assert_response :success
        assert_equal "verified", response.parsed_body.dig("data", "status")
        assert_equal "manual", response.parsed_body.dig("data", "verification_source")
      end

      test "regular attendee cannot manually verify a seller account" do
        post "/admin/marketplace/seller_payout_accounts/#{@pending.id}/verify",
             params: {
               reason: "Not authorized",
               evidence_reference: "case-2026-09-10-007"
             }, headers: user_headers.merge("Idempotency-Key" => "attendee-seller-verify"), as: :json

        assert_response :forbidden
        assert_equal "pending_verification", @pending.reload.status
      end

      test "admin verification requires reason and evidence" do
        post "/admin/marketplace/seller_payout_accounts/#{@pending.id}/verify",
             params: { reason: "", evidence_reference: "" },
             headers: admin_headers.merge("Idempotency-Key" => "admin-seller-verify-invalid"), as: :json

        assert_response :unprocessable_entity
        assert_equal "payout_account_verification_required", response.parsed_body.fetch("code")
      end

      test "admin verification requires an idempotency key" do
        post "/admin/marketplace/seller_payout_accounts/#{@pending.id}/verify",
             params: {
               reason: "Verified against seller-provided bank evidence",
               evidence_reference: "case-2026-09-10-008"
             }, headers: admin_headers, as: :json

        assert_response :bad_request
        assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
      end
    end
  end
end
