# frozen_string_literal: true

module Payments
  module Providers
    # Deterministic payment/refund provider for lifecycle tests. Outcomes are
    # explicitly queued per operation and idempotency-key requests are retained
    # for assertions; a missing outcome is always unknown, never success.
    class FakePaymentProvider < Adapter
      DEFAULT_BALANCE = { amount_minor: 100_000, currency: "ETB" }.freeze

      def initialize(outcomes: {}, capabilities: {}, available_balance: DEFAULT_BALANCE,
        settlement_grace_minutes: 5)
        @outcomes = Hash.new { |hash, operation| hash[operation] = [] }
        outcomes.each { |operation, values| @outcomes[operation].concat(Array(values)) }
        @capabilities = capabilities.to_h.deep_symbolize_keys.freeze
        @available_balance = available_balance&.to_h&.deep_symbolize_keys&.freeze
        @settlement_grace_minutes = settlement_grace_minutes
        @requests = Hash.new { |hash, key| hash[key] = [] }
      end

      def create(**request) = execute(:create, **request)

      def cancel(**request) = execute(:cancel, **request)

      def verify(**request) = execute(:verify, **request)

      def verify_webhook(**) = true

      def refund(**request) = execute(:refund, **request)

      def verify_refund(**request) = execute(:verify_refund, **request)

      def available_balance(**) = @available_balance

      def capabilities = @capabilities

      def settlement_grace_minutes = @settlement_grace_minutes

      def enqueue(operation, outcome)
        @outcomes[operation.to_sym] << outcome
        self
      end

      def requests_for(idempotency_key)
        @requests.fetch(idempotency_key.to_s, []).map(&:dup).freeze
      end

      private

      def execute(operation, **request)
        remember_request(request)
        normalize_result(@outcomes[operation].shift)
      end

      def remember_request(request)
        key = request[:idempotency_key].to_s
        @requests[key] << request.dup if key.present?
      end

      def normalize_result(outcome)
        return Result.unknown(raw_status: "no_outcome_configured") if outcome.nil?
        return outcome if outcome.is_a?(Result)

        Result.from_provider_response(outcome)
      end
    end
  end
end
