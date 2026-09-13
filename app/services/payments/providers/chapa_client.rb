# frozen_string_literal: true

require "bigdecimal"
require "cgi"
require "json"
require "openssl"

module Payments
  module Providers
    # Chapa V2 pay-in/refund contract. Domain services receive only the
    # canonical payment result; V2 paths, payloads, headers, and status
    # normalization stay behind this adapter seam.
    class ChapaClient
      DEFAULT_API_BASE_URL = "https://api.chapa.global"
      MODES = %w[test live].freeze

      def initialize(secret_key:, webhook_secret:, mode: "test", api_base_url: DEFAULT_API_BASE_URL,
        callback_url: nil, return_url: nil, transport: nil)
        @secret_key = secret_key.to_s
        @webhook_secret = webhook_secret.to_s
        @mode = mode.to_s
        @callback_url = callback_url.to_s.presence
        @return_url = return_url.to_s.presence
        validate_configuration!
        @transport = transport || Core::HttpTransport.new(base_url: api_base_url)
      end

      # Hosted checkout owns payment-method selection. Chapa documents the
      # preference field as optional but does not publish its wire shape, and
      # the live V2 endpoint rejected the string array used by the old client.
      def create(**request)
        return unsupported_amount_result if fractional_etb_amount?(request[:amount_minor], request[:currency])

        payload = payment_payload(request)
        map_result(post("/v2/payments/hosted", payload, idempotency_key: request[:idempotency_key]), checkout_url: true)
      end

      def direct_charge(**request)
        return unsupported_amount_result if fractional_etb_amount?(request[:amount_minor], request[:currency])

        payload = payment_payload(request).merge(payment_method: request.fetch(:payment_method).to_s)
        map_result(post("/v2/payments/direct", payload, idempotency_key: request[:idempotency_key]))
      end

      def verify(**request)
        reference = request[:provider_reference].presence || request.fetch(:idempotency_key)
        map_result(get("/v2/payments/#{CGI.escape(reference.to_s)}/verify"))
      end

      def refund(**request)
        if request[:refund_type] != "payment_reversal" &&
            fractional_etb_amount?(request[:amount_minor], request[:currency])
          return unsupported_amount_result
        end

        payload = {
          payment_reference: request.fetch(:provider_reference),
          merchant_reference: request.fetch(:idempotency_key),
          reason: request[:reason].to_s.strip.presence,
          meta: metadata(request)
        }.compact
        payload[:amount] = major_amount(request.fetch(:amount_minor)) unless request[:refund_type] == "payment_reversal"
        map_result(post("/v2/refunds", payload, idempotency_key: request[:idempotency_key]))
      end

      def verify_refund(**request)
        reference = request.fetch(:provider_reference)
        map_result(get("/v2/refunds/#{CGI.escape(reference.to_s)}/verify"))
      end

      # V2's public payout contract does not document a merchant-balance
      # endpoint. A nil result makes the higher-level refund path skip the
      # optional preflight rather than inventing a balance fact.
      def available_balance(**)
        nil
      end

      def verify_webhook(payload:, headers:, **_request)
        received = headers.to_h.each_with_object({}) do |(key, value), normalized|
          normalized[normalize_header_key(key)] = value.to_s
        end
        expected = OpenSSL::HMAC.hexdigest("SHA256", @webhook_secret, payload.to_s)
        return false unless secure_equal?(received["x-chapa-signature"], expected)

        webhook_mode_matches?(payload)
      end

      private

      Response = Data.define(:status, :body)

      def payment_payload(request)
        {
          amount: major_amount(request.fetch(:amount_minor)),
          currency: request.fetch(:currency).to_s.upcase,
          merchant_reference: request.fetch(:idempotency_key),
          customer: customer_payload(request),
          callback_url: @callback_url,
          return_url: @return_url,
          meta: metadata(request)
        }
      end

      def customer_payload(request)
        {
          first_name: request[:first_name].to_s.strip.presence,
          last_name: request[:last_name].to_s.strip.presence,
          email: request[:email].to_s.strip.presence,
          phone_number: chapa_phone(request[:phone_number])
        }.compact
      end

      def metadata(request)
        request[:meta].to_h.merge(
          payment_id: request[:payment_id],
          order_id: request[:order_id],
          billing_purchase_id: request[:billing_purchase_id]
        ).compact
      end

      def get(path) = request(:get, path)

      def post(path, payload, idempotency_key: nil)
        headers = { "Idempotency-Key" => idempotency_key.to_s.presence }.compact
        request(:post, path, JSON.generate(payload), "application/json", headers:)
      end

      def request(method, path, body = nil, content_type = "application/json", headers: {})
        response = @transport.call(
          method:, path:, body:,
          headers: { "Authorization" => "Bearer #{@secret_key}", "Content-Type" => content_type }.merge(headers)
        )
        Response.new(status: response.status.to_i, body: symbolize(response.body))
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        Result.timeout(raw_status: "provider_timeout")
      rescue StandardError
        Result.unknown(raw_status: "provider_exception")
      end

      def map_result(response, checkout_url: false)
        return response if response.is_a?(Result)
        return Result.unknown(raw_status: "provider_unavailable") if response.status >= 500

        data = response.body[:data].to_h
        return missing_checkout_url_result(response) if checkout_url && response.status.between?(200, 299) && !valid_checkout_url?(data[:checkout_url])

        provider_status = data[:status].presence || data[:payment_status].presence || response.body[:status]
        hosted_checkout = checkout_url && data[:checkout_url].present?
        status = hosted_checkout ? "pending" : provider_status
        failure_code = failure_code_for(status, data, response.body)
        log_provider_failure(response, status, failure_code)
        Result.new(
          status:,
          provider_reference: data[:chapa_reference].presence || data[:reference].presence ||
            data[:ref_id].presence || data[:tx_ref].presence,
          failure_code:,
          provider_fee_minor: minor_amount(data[:service_fee].presence || data[:charge]),
          provider_fee_currency: data[:currency],
          raw_status: hosted_checkout ? "initialized" : status,
          checkout_url: checkout_url ? data[:checkout_url] : nil,
          auth_type: data[:auth_type],
          request_id: data[:request_id]
        )
      end

      def missing_checkout_url_result(response)
        Rails.logger.warn("Chapa hosted initialization returned no checkout_url status_code=#{response.status}")
        Result.failure(failure_code: "checkout_url_missing", raw_status: "checkout_url_missing")
      end

      def valid_checkout_url?(value)
        value.to_s.match?(/\Ahttps:\/\/\S+\z/)
      end

      def symbolize(value)
        value.respond_to?(:deep_symbolize_keys) ? value.deep_symbolize_keys : {}
      end

      def failure_code_for(status, data, body)
        normalized_status = status.to_s.downcase
        return if normalized_status.in?(%w[
          success succeeded completed paid pending processing auth_needed otp_needed incomplete unknown
        ])

        candidate = data[:failure_code].presence || data.dig(:error, :code).presence ||
          data[:reason].presence || body.dig(:error, :code).presence || normalized_status
        candidate = "provider_rejected" if candidate.blank? || candidate == false
        candidate.to_s.downcase.gsub(/[^a-z0-9]+/, "_").sub(/\A_+|_+\z/, "")[0, 64]
      end

      def log_provider_failure(response, status, failure_code)
        return unless %w[failure failed declined error reversed blocked].include?(status.to_s.downcase)

        message = response.body[:message].to_s.gsub(/\s+/, " ").truncate(200)
        Rails.logger.warn(
          "Chapa provider rejected response status_code=#{response.status} " \
          "status=#{status} failure_code=#{failure_code} message=#{message}"
        )
      end

      def major_amount(amount_minor)
        amount = Integer(amount_minor)
        raise ArgumentError unless amount.positive?

        Core::JsonNumber.new((BigDecimal(amount.to_s) / 100).to_s("F"))
      end

      def chapa_phone(value)
        phone = value.to_s.strip
        return if phone.blank?
        return phone if phone.start_with?("+")

        normalized = phone.sub(/\A00/, "")
        normalized = normalized.sub(/\A0/, "251") unless normalized.start_with?("251")
        "+#{normalized}"
      end

      def fractional_etb_amount?(amount_minor, currency)
        return false unless currency.to_s.strip.upcase == "ETB"

        amount = Integer(amount_minor)
        amount.positive? && (amount % 100).positive?
      rescue ArgumentError, TypeError
        false
      end

      def unsupported_amount_result
        Result.failure(failure_code: "amount_precision_unsupported", raw_status: "amount_precision_unsupported")
      end

      def minor_amount(amount)
        return if amount.blank?

        (BigDecimal(amount.to_s) * 100).round(0).to_i
      end

      def secure_equal?(left, right)
        left.present? && left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
      end

      def webhook_mode_matches?(payload)
        parsed = JSON.parse(payload.to_s)
        mode = parsed["mode"].to_s.presence
        mode.blank? || mode == @mode
      rescue JSON::ParserError
        false
      end

      def normalize_header_key(key)
        key.to_s.sub(/\AHTTP_/i, "").downcase.tr("_", "-")
      end

      def validate_configuration!
        raise ArgumentError, I18n.t("payments.providers.errors.invalid_mode", modes: MODES.join(", ")) unless MODES.include?(@mode)
        raise ArgumentError, I18n.t("payments.providers.errors.secrets_required") if @secret_key.blank? || @webhook_secret.blank?

        prefix = @mode == "test" ? "CHAPA_TEST_" : "CHAPA_LIVE_"
        raise ArgumentError, I18n.t("payments.providers.errors.secret_prefix", mode: @mode, prefix:) unless @secret_key.start_with?(prefix)
      end
    end
  end
end
