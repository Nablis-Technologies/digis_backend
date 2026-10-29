# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class CreditAccountsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    test "returns separate channel credit balances for an organization" do
      organization = create_test_organization
      CreditAccount.create!(organization:, channel: "sms")
      CreditAccount.create!(organization:, channel: "email")

      get "/organizations/#{organization.id}/messaging/credits", headers: admin_headers, as: :json

      assert_response :success
      assert_equal %w[email sms], JSON.parse(response.body).fetch("data").map { |row| row.fetch("channel") }
      assert JSON.parse(response.body).fetch("data").all? { |row| row.fetch("available") == 0 }
    end

    test "lists only safe ledger fields for the organization" do
      organization = create_test_organization
      account = CreditAccount.create!(organization:, channel: "sms")
      CreditLedgerEntry.create!(
        credit_account: account, entry_type: "top_up", quantity: 10, available_delta: 10,
        idempotency_key_digest: Digest::SHA256.hexdigest("api-ledger"), metadata: { "secret" => "never" }
      )

      get "/organizations/#{organization.id}/messaging/credit_ledger?page=1", headers: admin_headers, as: :json

      assert_response :success
      row = JSON.parse(response.body).fetch("data").first
      assert_equal %w[available_delta created_at credit_account_id entry_type id quantity reference_id reference_type rate_version_id].sort,
        row.keys.sort
      refute row.key?("metadata")
    end

    private

    def create_test_organization
      Organizations::Organization.create!(
        name: "Credit API #{SecureRandom.hex(6)}", slug: "credit-api-#{SecureRandom.hex(6)}",
        organizer_type: "company", category: "conference"
      )
    end
  end
end
