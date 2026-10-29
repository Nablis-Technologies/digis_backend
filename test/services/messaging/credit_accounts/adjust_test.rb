# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module CreditAccounts
    class AdjustTest < ActiveSupport::TestCase
      setup do
        @organization = organizations_organizations(:one)
        @actor = core_users(:super_admin)
        @account = Messaging::CreditAccount.create!(organization: @organization, channel: "sms")
        Messaging::CreditLedgerEntry.create!(
          credit_account: @account, entry_type: "top_up", quantity: 50, available_delta: 50,
          idempotency_key_digest: Digest::SHA256.hexdigest("seed-adjust"), metadata: {}
        )
      end

      test "requires an administrator and reason, then appends an idempotent correction" do
        operation = -> {
          Adjust.call(
            account: @account, organization: @organization, quantity: 10, actor: @actor,
            reason: "support correction", idempotency_key: "adjust-1"
          )
        }

        assert_idempotent(operation, counter: -> { Messaging::CreditLedgerEntry.where(entry_type: "adjustment").count })
        assert_equal 60, @account.reload.ledger_entries.sum(:available_delta)
      end

      test "rejects a negative adjustment that would make the balance negative" do
        result = Adjust.call(
          account: @account, organization: @organization, quantity: -51, actor: @actor,
          reason: "correction", idempotency_key: "adjust-too-much"
        )

        assert_predicate result, :failure?
        assert_equal "insufficient_credits", result.error.code
      end

      test "preserves a typed scope error" do
        other_organization = Organizations::Organization.create!(
          name: "Other Adjust #{SecureRandom.hex(4)}", slug: "other-adjust-#{SecureRandom.hex(4)}",
          organizer_type: "company", category: "conference"
        )

        result = Adjust.call(
          account: @account, organization: other_organization, quantity: 1, actor: @actor,
          reason: "scope check", idempotency_key: "adjust-scope"
        )

        assert_predicate result, :failure?
        assert_equal "credit_account_scope_invalid", result.error.code
      end

      test "returns a typed failure for a malformed idempotency key" do
        result = Adjust.call(
          account: @account, organization: @organization, quantity: 1, actor: @actor,
          reason: "invalid key", idempotency_key: nil
        )

        assert_predicate result, :failure?
        assert_equal "invalid_idempotency_key", result.error.code
      end
    end
  end
end
