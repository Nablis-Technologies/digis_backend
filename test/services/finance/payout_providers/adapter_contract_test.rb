# frozen_string_literal: true

require "test_helper"

module Finance
  module PayoutProviders
    class AdapterContractTest < ActiveSupport::TestCase
      class FakeClient
        def payout(**)
          { status: "paid", provider_reference: "payout-ref", raw_status: "paid" }
        end

        def verify_payout(**)
          { status: "pending", raw_status: "pending" }
        end

        def available_balance(**)
          { amount_minor: 10_000, currency: "ETB" }
        end
      end

      test "normalizes payout provider statuses into a finite result contract" do
        success = Result.from_provider_response(
          status: "paid", provider_reference: "ref-1", raw_status: "paid"
        )
        timeout = Result.timeout(raw_status: "timeout")

        assert_equal "success", success.status
        assert_equal "timeout", timeout.status
        assert_predicate success, :frozen?
      end

      test "the base adapter exposes the payout and balance boundary" do
        adapter = ChapaAdapter.new(client: FakeClient.new)

        Adapter::REQUIRED_METHODS.each do |method_name|
          assert_respond_to adapter, method_name
        end

        assert_equal "success", adapter.payout(amount_minor: 1_000, currency: "ETB").status
        assert_equal "unknown", adapter.verify_payout(idempotency_key: "payout-1").status
        assert_equal 10_000, adapter.available_balance(currency: "ETB").fetch(:amount_minor)
      end
    end
  end
end
