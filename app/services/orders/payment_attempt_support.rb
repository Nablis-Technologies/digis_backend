# frozen_string_literal: true

module Orders
  # Shared provider-boundary behavior for event and billing payment attempts.
  # Subject-specific coordinators own their locks and invariants, while this
  # module keeps normalization, capability checks, status mapping, and abort
  # translation identical across both flows.
  module PaymentAttemptSupport
    # Internal control flow used to return typed business failures from the
    # reservation transaction without exposing exception details to callers.
    class AttemptAbort < Core::Error
      attr_reader :business_error

      def initialize(error)
        @business_error = error
        super(error.message)
      end
    end

    private

    def prepare_idempotency!
      @idempotency_key = Core::IdempotencyKey.new(raw_idempotency_key).to_s
    end

    def resolve_payment_adapter(currency:, invalid_provider_key: :invalid_payment_provider)
      return failure_result(invalid_provider_key, code: "invalid_payment_provider") unless Payment::PROVIDERS.include?(provider)
      return failure_result(:invalid_payment_method, code: "invalid_payment_method") unless Payment::PAYMENT_METHODS.include?(payment_method)

      adapter = Payments::Providers::Registry.fetch(provider)
      return failure_result(:provider_method_unsupported, code: "payment_method_unsupported") unless supported?(adapter, :payment_methods, payment_method)
      return failure_result(:provider_currency_unsupported, code: "payment_currency_unsupported") unless supported?(adapter, :currencies, currency)

      success(adapter)
    rescue KeyError, ArgumentError
      failure_result(:provider_unavailable, code: "payment_provider_unavailable", status: :service_unavailable)
    end

    def supported?(adapter, key, expected)
      values = capability(adapter, key)
      return true if values.blank?

      Array(values).map { |value| value.to_s.downcase }.include?(expected.to_s.downcase)
    end

    def capability(adapter, key)
      capabilities = adapter.capabilities.to_h
      capabilities[key] || capabilities[key.to_s]
    end

    def payment_status_for(result)
      return "processing" if result.status.in?(%w[unknown timeout])

      { "success" => "succeeded", "failure" => "failed", "cancelled" => "cancelled" }.fetch(result.status)
    end

    def recover_invalid_provider_result(payment:, result:)
      payment.update_columns(
        status: "processing",
        provider_reference: result.provider_reference,
        failure_code: nil,
        provider_fee_minor: nil,
        provider_fee_currency: nil,
        checkout_url: payment.checkout_url,
        raw_status: "provider_result_invalid",
        updated_at: Time.current
      )
      success(payment.reload)
    end

    def failure_result(key, code:, status: :unprocessable_entity)
      failure(payment_error(key, code:, status:))
    end

    def payment_error(key, code:, status: :unprocessable_entity, errors: nil)
      Core::BusinessError.new(I18n.t("orders.payments.errors.#{key}"), code:, status:, errors:)
    end

    def abort_with(error)
      raise PaymentAttemptSupport::AttemptAbort, error
    end
  end
end
