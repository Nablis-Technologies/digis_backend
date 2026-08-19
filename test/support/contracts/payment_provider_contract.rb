# frozen_string_literal: true

module Payments
  module Providers
    # Shared provider lifecycle assertions. Order, webhook, and refund state
    # transitions remain owned by their service/integration tests; this contract
    # proves every payment adapter exposes the same normalized provider boundary.
    module PaymentProviderContract
      extend ActiveSupport::Concern

      included do
        test "supports every required operation and normalizes success" do
          adapter = build_adapter(
            outcomes: { create: [ Result.success(provider_reference: "contract-ref") ] }
          )

          Adapter::REQUIRED_METHODS.each { |method_name| assert_respond_to adapter, method_name }
          result = adapter.create(idempotency_key: "contract-create", amount_minor: 1_000, currency: "ETB")

          assert_instance_of Result, result
          assert_equal "success", result.status
          assert_equal "contract-ref", result.provider_reference
          assert_predicate result, :frozen?
        end

        test "distinguishes rejection and timeouts before or after a provider reference" do
          adapter = build_adapter(
            outcomes: {
              create: [
                Result.failure(failure_code: "declined", raw_status: "declined"),
                Result.timeout(raw_status: "gateway_timeout"),
                Result.timeout(provider_reference: "accepted-ref", raw_status: "pending")
              ]
            }
          )

          rejected = adapter.create(idempotency_key: "rejected", amount_minor: 1_000, currency: "ETB")
          before_reference = adapter.create(idempotency_key: "before-reference", amount_minor: 1_000, currency: "ETB")
          after_reference = adapter.create(idempotency_key: "after-reference", amount_minor: 1_000, currency: "ETB")

          assert_predicate rejected, :failure?
          assert_predicate before_reference, :timeout?
          assert_nil before_reference.provider_reference
          assert_predicate after_reference, :timeout?
          assert_equal "accepted-ref", after_reference.provider_reference
        end

        test "keeps repeated unknown verification pending until it later resolves" do
          adapter = build_adapter(
            outcomes: {
              verify: [
                Result.unknown(raw_status: "pending"),
                Result.unknown(raw_status: "processing"),
                Result.success(provider_reference: "resolved-ref")
              ]
            }
          )

          first = adapter.verify(idempotency_key: "verify-key")
          second = adapter.verify(idempotency_key: "verify-key")
          resolved = adapter.verify(idempotency_key: "verify-key")

          assert_predicate first, :unknown?
          assert_predicate second, :unknown?
          assert_predicate resolved, :success?
          assert_equal "resolved-ref", resolved.provider_reference
        end

        test "preserves refund fee evidence and sanitized raw status" do
          adapter = build_adapter(
            outcomes: {
              refund: [
                Result.success(
                  provider_reference: "refund-ref",
                  provider_fee_minor: 25,
                  provider_fee_currency: "ETB",
                  raw_status: "refunded"
                )
              ]
            }
          )

          result = adapter.refund(idempotency_key: "refund-key", amount_minor: 1_000, currency: "ETB")

          assert_predicate result, :success?
          assert_equal 25, result.provider_fee_minor
          assert_equal "ETB", result.provider_fee_currency
          assert_equal "refunded", result.raw_status
          refute_match(/password|token|secret|payload/i, result.raw_status.to_s)
        end

        test "exposes capability and liquidity boundaries without changing result semantics" do
          adapter = build_adapter(
            outcomes: {},
            capabilities: { refunds: { supported: true, partial: false, fee_estimate_minor: 25 } },
            available_balance: { amount_minor: 999, currency: "ETB" }
          )

          assert_equal(
            { supported: true, partial: false, fee_estimate_minor: 25 },
            adapter.refund_capabilities
          )
          assert_equal({ amount_minor: 999, currency: "ETB" }, adapter.available_balance(currency: "ETB"))
        end
      end

      private

      def build_adapter(**)
        raise NotImplementedError
      end
    end
  end
end
