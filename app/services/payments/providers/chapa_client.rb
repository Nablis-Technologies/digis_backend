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
        @callback_url = callback_url.to_s.strip.presence
        @return_url = return_url.to_s.strip.presence
        validate_configuration!
        @transport = transport || Core::HttpTransport.new(base_url: api_base_url)
      end

      def merchant_reference(subject_id:, idempotency_key:, attempt_number: nil)
        Core::ProviderMerchantReference.call(
          provider: "chapa", subject_id:, idempotency_key:, attempt_number:
        )
      end

      # Hosted checkout owns payment-method selection. Chapa documents the
      # preference field as optional but does not publish its wire shape, and
      # the live V2 endpoint rejected the string array used by this adapter.
      def create(**request)
        payload = payment_payload(request, include_redirects: true)
        map_result(post("/v2/payments/hosted", payload, idempotency_key: request[:idempotency_key]), checkout_url: true)
      end

      def direct_charge(**request)
        payload = payment_payload(request).merge(payment_method: request.fetch(:payment_method).to_s)
        map_result(post("/v2/payments/direct", payload, idempotency_key: request[:idempotency_key]))
      end

      def cancel(**)
        Result.failure(failure_code: "cancellation_unsupported", raw_status: "cancellation_unsupported")
      end

      def verify(**request)
        reference = request[:provider_reference].presence || request[:merchant_reference].presence ||
          merchant_reference_for(request)
        map_result(get("/v2/payments/#{CGI.escape(reference.to_s)}/verify"))
      end

      def refund(**request)
        payload = {
          payment_reference: request.fetch(:provider_reference),
          merchant_reference: merchant_reference_for(request),
          reason: request[:reason].to_s.strip.presence,
          meta: metadata(request)
        }.compact
        payload[:amount] = integer_amount(request.fetch(:amount_minor)) unless request[:refund_type] == "payment_reversal"
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

      def verify_webhook(payload:, headers:, signature: nil, **_request)
        received = headers.to_h.each_with_object({}) do |(key, value), normalized|
          normalized[normalize_header_key(key)] = value.to_s
        end
        expected = OpenSSL::HMAC.hexdigest("SHA256", @webhook_secret, payload.to_s)
        received_signature = signature.to_s.presence || received["x-chapa-signature"]
        unless secure_equal?(received_signature, expected)
          log_webhook_signature_diagnostic(received_signature, expected, payload, received)
          return false
        end

        webhook_mode_matches?(payload)
      end

      private

      Response = Data.define(:status, :body)

      def payment_payload(request, include_redirects: false)
        payload = {
          amount: integer_amount(request.fetch(:amount_minor)),
          currency: request.fetch(:currency).to_s.upcase,
          merchant_reference: merchant_reference_for(request),
          customer: customer_payload(request),
          meta: metadata(request)
        }
        payload.merge!(callback_url: @callback_url, return_url: @return_url) if include_redirects
        payload.compact
      end

      def merchant_reference_for(request)
        reference = request[:merchant_reference].to_s.strip.presence
        return reference if reference && reference.length <= Core::ProviderMerchantReference::LENGTH

        merchant_reference(
          subject_id: request[:subject_id].presence || request[:payment_id].presence || request[:order_id].presence ||
            request[:billing_purchase_id].presence || "payment",
          idempotency_key: request.fetch(:idempotency_key), attempt_number: request[:attempt_number]
        )
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
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => error
        log_transport_failure(method:, error:)
        Result.timeout(raw_status: "provider_timeout")
      rescue StandardError => error
        log_transport_failure(method:, error:)
        Result.unknown(raw_status: "provider_exception")
      end

      def map_result(response, checkout_url: false)
        return response if response.is_a?(Result)
        if response.status >= 500
          failure_code = provider_failure_code(response)
          log_http_failure(response, failure_code)
          return Result.unknown(
            failure_code:, raw_status: "provider_unavailable", request_id: provider_request_id(response)
          )
        end

        data = response.body[:data].to_h
        if response.status >= 400
          failure_code = failure_code_for("failure", data, response.body)
          log_http_failure(response, failure_code)
          return Result.failure(failure_code: failure_code, raw_status: "provider_rejected")
        end

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

      def log_http_failure(response, failure_code)
        message = response.body[:message].to_s.gsub(/\s+/, " ").truncate(200)
        request_id = provider_request_id(response)
        request_id = " request_id=#{request_id}" if request_id.present?
        Rails.logger.warn(
          "Chapa provider response status_code=#{response.status} " \
          "failure_code=#{failure_code}#{request_id} message=#{message}"
        )
      end

      def provider_failure_code(response)
        failure_code_for("failure", response.body[:data].to_h, response.body)
      end

      def provider_request_id(response)
        details = response.body.dig(:error, :details)
        return unless details.respond_to?(:to_h)

        attributes = details.to_h
        attributes[:request_id].presence || attributes["request_id"].presence
      end

      def log_transport_failure(method:, error:)
        Rails.logger.warn("Chapa provider transport failure method=#{method} error=#{error.class}")
      end

      def symbolize(value)
        value.respond_to?(:deep_symbolize_keys) ? value.deep_symbolize_keys : {}
      end

      def failure_code_for(status, data, body)
        normalized_status = status.to_s.downcase
        return if normalized_status.in?(%w[
          success succeeded completed paid pending processing auth_needed otp_needed incomplete unknown
        ])

        candidate = data[:failure_code].presence || nested_error_code(data[:error]) ||
          data[:reason].presence || nested_error_code(body[:error]) || body[:code].presence || normalized_status
        candidate = "provider_rejected" if candidate.blank? || candidate == false
        candidate.to_s.downcase.gsub(/[^a-z0-9]+/, "_").sub(/\A_+|_+\z/, "")[0, 64]
      end

      def nested_error_code(value)
        return unless value.respond_to?(:to_h)

        attributes = value.to_h
        attributes[:code].presence || attributes["code"].presence
      end

      def log_provider_failure(response, status, failure_code)
        return unless %w[failure failed declined error reversed blocked].include?(status.to_s.downcase)

        message = response.body[:message].to_s.gsub(/\s+/, " ").truncate(200)
        Rails.logger.warn(
          "Chapa provider rejected response status_code=#{response.status} " \
          "status=#{status} failure_code=#{failure_code} message=#{message}"
        )
      end

      def integer_amount(amount_minor)
        amount = Integer(amount_minor)
        raise ArgumentError unless amount.positive?

        amount
      end

      def chapa_phone(value)
        phone = value.to_s.strip
        return if phone.blank?
        return phone if phone.start_with?("+")

        normalized = phone.sub(/\A00/, "")
        normalized = normalized.sub(/\A0/, "251") unless normalized.start_with?("251")
        "+#{normalized}"
      end

      def minor_amount(amount)
        return if amount.blank?

        (BigDecimal(amount.to_s) * 100).round(0).to_i
      end

      def secure_equal?(left, right)
        left.present? && left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
      end

      def log_webhook_signature_diagnostic(received_signature, expected, payload, headers)
        signature_headers = headers.keys.grep(/signature/).sort.join(",").presence || "none"
        content_length = headers["content-length"].presence || "unknown"
        Rails.logger.warn(
          "[CHAPA-WEBHOOK-DIAGNOSTIC] signature_present=#{received_signature.present?} " \
          "signature_length=#{received_signature.to_s.bytesize} expected_length=#{expected.bytesize} " \
          "raw_payload_bytes=#{payload.to_s.bytesize} content_length=#{content_length} " \
          "signature_headers=#{signature_headers}"
        )
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
