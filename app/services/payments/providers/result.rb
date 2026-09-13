# frozen_string_literal: true

module Payments
  module Providers
    # Provider responses are normalized before they cross into Orders. The
    # raw provider status is retained for reconciliation, while orchestration
    # uses only this finite, provider-neutral status set.
    Result = Data.define(
      :status, :provider_reference, :failure_code, :provider_fee_minor,
      :provider_fee_currency, :raw_status, :checkout_url, :auth_type, :request_id
    ) do
      STATUSES = %w[success failure cancelled unknown timeout].freeze
      STATUS_MAP = {
        "success" => "success", "succeeded" => "success", "paid" => "success", "completed" => "success",
        "refunded" => "success",
        "failure" => "failure", "failed" => "failure", "declined" => "failure", "error" => "failure",
        "reversed" => "failure", "blocked" => "unknown",
        "cancelled" => "cancelled", "canceled" => "cancelled",
        "timeout" => "timeout", "timed_out" => "timeout",
        "unknown" => "unknown", "pending" => "unknown", "processing" => "unknown"
      }.freeze

      def initialize(status:, provider_reference: nil, failure_code: nil, provider_fee_minor: nil,
                     provider_fee_currency: nil, raw_status: nil, checkout_url: nil,
                     auth_type: nil, request_id: nil)
        normalized_status = STATUS_MAP.fetch(status.to_s.downcase, "unknown")
        normalized_currency = provider_fee_currency.to_s.upcase.presence
        if provider_fee_minor.present? && provider_fee_minor.to_i.negative?
          fail ArgumentError, I18n.t("payments.providers.errors.invalid_result")
        end

        super(
          status: normalized_status,
          provider_reference: provider_reference.to_s.presence,
          failure_code: failure_code.to_s.presence,
          provider_fee_minor: provider_fee_minor,
          provider_fee_currency: normalized_currency,
          raw_status: raw_status.to_s.presence,
          checkout_url: checkout_url.to_s.presence,
          auth_type: auth_type.to_s.presence,
          request_id: request_id.to_s.presence
        )
      end

      def self.from_provider_response(response)
        attributes = response.to_h.symbolize_keys
        new(**attributes.slice(
          :status, :provider_reference, :failure_code, :provider_fee_minor,
          :provider_fee_currency, :raw_status, :checkout_url, :auth_type, :request_id
        ))
      end

      def self.success(**attributes) = new(status: "success", **attributes)

      def self.failure(**attributes) = new(status: "failure", **attributes)

      def self.cancelled(**attributes) = new(status: "cancelled", **attributes)

      def self.unknown(**attributes) = new(status: "unknown", **attributes)

      def self.timeout(**attributes) = new(status: "timeout", **attributes)

      def success? = status == "success"

      def failure? = status == "failure"

      def cancelled? = status == "cancelled"

      def unknown? = status == "unknown"

      def timeout? = status == "timeout"
    end
  end
end
