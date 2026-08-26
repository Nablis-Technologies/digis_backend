# frozen_string_literal: true

require "test_helper"

module Finance
  module PayoutAccounts
    class RegisterTest < ActiveSupport::TestCase
      class FakeAdapter < Finance::PayoutProviders::Adapter
        attr_reader :verification_requests
        attr_accessor :banks

        def initialize(result)
          @result = result
          @verification_requests = []
          @banks = nil
        end

        def verify_payout_account(**request)
          verification_requests << request
          @result
        end

        def available_banks(**)
          banks
        end
      end

      setup do
        @organization = organizations_organizations(:one)
        @actor = core_users(:super_admin)
        @attributes = {
          organization: @organization,
          type: "bank",
          provider: "chapa",
          bank_code: 128,
          account_number: "1000000000001",
          account_name: "Digis Organizer",
          account_label: "Primary account",
          actor: @actor,
          idempotency_key: "payout-account-register-1"
        }
      end

      test "persists a verified account when the provider verifies it" do
        adapter = FakeAdapter.new(Finance::PayoutProviders::Result.success)

        result = Register.call(**@attributes, adapter:)

        assert_predicate result, :success?, result.error&.message
        assert_predicate result.value, :verified?
        assert_equal "provider", result.value.verification_source
        assert_equal "1000000000001", adapter.verification_requests.sole.fetch(:account_number)
        assert_equal 128, adapter.verification_requests.sole.fetch(:bank_code)
      end

      test "leaves the account pending when provider verification is unsupported" do
        adapter = FakeAdapter.new(Finance::PayoutProviders::Result.unknown(raw_status: "unsupported"))

        result = Register.call(**@attributes, adapter:)

        assert_predicate result, :success?, result.error&.message
        assert_equal "pending_verification", result.value.status
        assert_nil result.value.verification_source
      end

      test "allows a synthetic fixture to be verified without a provider call" do
        adapter = FakeAdapter.new(Finance::PayoutProviders::Result.unknown(raw_status: "unused"))

        result = Register.call(**@attributes, adapter:, verification_source: "test_fixture")

        assert_predicate result, :success?, result.error&.message
        assert_predicate result.value, :verified?
        assert_equal "test_fixture", result.value.verification_source
        assert_empty adapter.verification_requests
      end

      test "replays the same registration without another provider verification" do
        adapter = FakeAdapter.new(Finance::PayoutProviders::Result.success)

        first = Register.call(**@attributes, adapter:)
        replay = Register.call(**@attributes, adapter:)

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert_equal first.value.id, replay.value.id
        assert_equal 1, adapter.verification_requests.length
      end

      test "rejects an idempotency key reused for a different registration" do
        adapter = FakeAdapter.new(Finance::PayoutProviders::Result.success)

        first = Register.call(**@attributes, adapter:)
        second = Register.call(
          **@attributes.merge(account_number: "1000000000002"), adapter:
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "idempotency_conflict", second.error.code
        assert_equal 1, adapter.verification_requests.length
      end

      test "rejects a bank code absent from the provider bank list" do
        adapter = FakeAdapter.new(Finance::PayoutProviders::Result.success)
        adapter.banks = [ 999 ]

        result = Register.call(**@attributes, adapter:)

        assert_predicate result, :failure?
        assert_equal "payout_account_bank_unsupported", result.error.code
      end
    end
  end
end
