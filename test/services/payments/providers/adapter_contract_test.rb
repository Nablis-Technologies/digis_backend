# frozen_string_literal: true

require "test_helper"

module Payments
  module Providers
    class AdapterContractTest < ActiveSupport::TestCase
      class FakeClient
        def verify_webhook(**)
          true
        end

        def create(**)
          { status: "paid", provider_reference: "chapa-ref", provider_fee_minor: 75,
            provider_fee_currency: "ETB", raw_status: "paid" }
        end

        def cancel(**)
          { status: "cancelled", raw_status: "cancelled" }
        end

        def verify(**)
          { status: "pending", raw_status: "pending" }
        end

        def refund(**)
          { status: "success", provider_reference: "refund-ref", raw_status: "refunded" }
        end

        def verify_refund(**)
          { status: "timeout", raw_status: "timeout" }
        end

        def available_balance(**)
          { amount_minor: 10_000, currency: "ETB" }
        end
      end

      test "normalizes provider statuses into the canonical result contract" do
        success = Result.from_provider_response(
          status: "paid", provider_reference: "ref-1", provider_fee_minor: 10,
          provider_fee_currency: "ETB", raw_status: "paid"
        )
        failure = Result.failure(failure_code: "declined", raw_status: "declined")
        cancelled = Result.cancelled(raw_status: "cancelled")
        unknown = Result.unknown(raw_status: "pending")
        timeout = Result.timeout(raw_status: "timeout")

        assert_equal "success", success.status
        assert_equal "failure", failure.status
        assert_equal "cancelled", cancelled.status
        assert_equal "unknown", unknown.status
        assert_equal "timeout", timeout.status
        assert_predicate success, :frozen?
      end

      test "Chapa implements every provider operation without recalculating fees" do
        adapter = ChapaAdapter.new(client: FakeClient.new)

        Adapter::REQUIRED_METHODS.each do |method_name|
          assert_respond_to adapter, method_name
        end

        result = adapter.create(
          amount_minor: 1_000,
          currency: "ETB",
          commercial_signature: "a" * 64
        )

        assert_equal "success", result.status
        assert_equal 75, result.provider_fee_minor
        assert_equal "ETB", result.provider_fee_currency
        assert_equal 5, adapter.settlement_grace_minutes
        assert_equal 10_000, adapter.available_balance(currency: "ETB").fetch(:amount_minor)
      end

      test "normalizes the optional refund capability contract" do
        adapter = ChapaAdapter.new(
          capabilities: { refunds: { supported: true, partial: false, fee_estimate_minor: 25 } }
        )

        assert_equal(
          { supported: true, partial: false, fee_estimate_minor: 25 },
          adapter.refund_capabilities
        )
      end

      test "registry accepts the same commercial signature across providers" do
        result = Registry.check_commercial_compatibility(
          expected_signature: "a" * 64,
          actual_signature: "a" * 64
        )

        assert_predicate result, :success?
      end

      test "registry returns a localized requote failure for changed commercial evidence" do
        result = Registry.check_commercial_compatibility(
          expected_signature: "a" * 64,
          actual_signature: "b" * 64
        )

        assert_predicate result, :failure?
        assert_equal "commercial_requote_required", result.error.code
        assert_equal :conflict, result.error.status
      end
    end
  end
end
