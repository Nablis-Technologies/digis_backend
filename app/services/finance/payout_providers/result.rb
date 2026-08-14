# frozen_string_literal: true

module Finance
  module PayoutProviders
    # Provider responses are normalized before payout orchestration sees them.
    # Unknown and timeout states intentionally remain distinct from failure so
    # a crashed request can be reconciled without sending the payout twice.
    Result = Data.define(:status, :provider_reference, :failure_code, :raw_status) do
      STATUSES = %w[success failure cancelled unknown timeout].freeze
      STATUS_MAP = {
        "success" => "success", "succeeded" => "success", "paid" => "success", "completed" => "success",
        "failure" => "failure", "failed" => "failure", "declined" => "failure", "error" => "failure",
        "cancelled" => "cancelled", "canceled" => "cancelled",
        "unknown" => "unknown", "pending" => "unknown", "processing" => "unknown",
        "timeout" => "timeout", "timed_out" => "timeout"
      }.freeze

      def initialize(status:, provider_reference: nil, failure_code: nil, raw_status: nil)
        normalized_status = STATUS_MAP.fetch(status.to_s.downcase, "unknown")

        super(
          status: normalized_status,
          provider_reference: provider_reference.to_s.presence,
          failure_code: failure_code.to_s.presence,
          raw_status: raw_status.to_s.presence
        )
      end

      def self.from_provider_response(response)
        return response if response.is_a?(self)

        attributes = response.to_h.symbolize_keys
        new(**attributes.slice(:status, :provider_reference, :failure_code, :raw_status))
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
