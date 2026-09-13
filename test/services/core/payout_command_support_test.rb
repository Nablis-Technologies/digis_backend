# frozen_string_literal: true

require "test_helper"

module Core
  class PayoutCommandSupportTest < ActiveSupport::TestCase
    class FakeCommand
      include Core::PayoutCommandSupport

      def command_error(*); end

      def replay_account(*); end

      private

      def payout_command_audit_prefix
        "test-payout-account"
      end

      def payout_command_identity_namespace
        "test-payout-account-idempotency"
      end
    end

    test "builds domain-configured audit keys" do
      command = FakeCommand.new
      key = Core::IdempotencyKey.new("support-test-key")

      assert_equal "test-payout-account-registered-#{key.digest}",
        command.send(:command_audit_key, "registered", key)
    end

    test "canonicalizes request identity before digesting" do
      command = FakeCommand.new
      first = command.send(
        :command_request_digest,
        operation: "set_default", account_id: "account-1", actor: nil,
        identity: { provider: "chapa", fields: { bank_slug: "cbe", type: "bank" } }
      )
      second = command.send(
        :command_request_digest,
        operation: "set_default", account_id: "account-1", actor: nil,
        identity: { fields: { type: "bank", bank_slug: "cbe" }, provider: "chapa" }
      )

      assert_equal first, second
    end
  end
end
