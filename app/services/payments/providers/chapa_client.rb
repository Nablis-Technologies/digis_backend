# frozen_string_literal: true

require "bigdecimal"
require "cgi"
require "json"
require "openssl"

module Payments
  module Providers
    # Chapa's HTTP contract is isolated here. The adapter and Orders receive
    # only canonical results, while this client owns Chapa paths, payload
    # shapes, test/live key validation, money conversion, and webhook HMACs.
    class ChapaClient
      DEFAULT_API_BASE_URL = "https://api.chapa.co/v1"
      MODES = %w[test live].freeze

      def initialize(secret_key:, webhook_secret:, mode: "test", api_base_url: DEFAULT_API_BASE_URL,
        callback_url: nil, return_url: nil, transport: nil)
        @secret_key = secret_key.to_s
        @webhook_secret = webhook_secret.to_s
        @mode = mode.to_s
        @callback_url = callback_url.to_s.presence
        @return_url = return_url.to_s.presence
        validate_configuration!
        @transport = transport || ChapaHttpTransport.new(base_url: api_base_url)
      end

      def create(**request)
        payload = {
          amount: major_amount(request.fetch(:amount_minor)),
          currency: request.fetch(:currency).to_s.upcase,
          tx_ref: request.fetch(:idempotency_key),
          email: request[:email].to_s.strip.presence,
          first_name: request[:first_name].to_s.strip.presence,
          last_name: request[:last_name].to_s.strip.presence,
          phone_number: chapa_phone(request[:phone_number]),
          callback_url: @callback_url,
          return_url: @return_url
        }.compact
        map_result(post("/transaction/initialize", payload), checkout_url: true)
      end

      def verify(**request)
        reference = request[:provider_reference].presence || request.fetch(:idempotency_key)
        map_result(get("/transaction/verify/#{CGI.escape(reference.to_s)}"))
      end

      def refund(**request)
        payload = {
          amount: major_amount(request.fetch(:amount_minor)),
          reference: request.fetch(:idempotency_key)
        }
        map_result(post_form("/refund/#{CGI.escape(request.fetch(:provider_reference).to_s)}", payload))
      end

      def verify_refund(**request)
        path = "/refund/#{CGI.escape(request.fetch(:provider_reference).to_s)}/verify"
        map_result(get(path))
      end

      def available_balance(**request)
        response = get("/balances/#{request.fetch(:currency).to_s.downcase}")
        return unless response.is_a?(Response)
        return unless response.status.between?(200, 299)

        balance = Array(response.body[:data]).find do |entry|
          entry[:currency].to_s.upcase == request.fetch(:currency).to_s.upcase
        end
        return unless balance

        {
          amount_minor: minor_amount(balance[:available_balance]),
          currency: balance[:currency].to_s.upcase
        }.freeze
      end

      def verify_webhook(payload:, headers:, **_request)
        received = headers.to_h.each_with_object({}) do |(key, value), normalized|
          normalized[normalize_header_key(key)] = value.to_s
        end
        expected = OpenSSL::HMAC.hexdigest("SHA256", @webhook_secret, payload.to_s)
        %w[chapa-signature x-chapa-signature].any? do |header|
          secure_equal?(received[header], expected)
        end
      end

      private

      Response = Data.define(:status, :body)

      def get(path) = request(:get, path)

      def post(path, payload) = request(:post, path, JSON.generate(payload), "application/json")

      def post_form(path, payload)
        request(:post, path, URI.encode_www_form(payload), "application/x-www-form-urlencoded")
      end

      def request(method, path, body = nil, content_type = "application/json")
        response = @transport.call(
          method:, path:, body:,
          headers: { "Authorization" => "Bearer #{@secret_key}", "Content-Type" => content_type }
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
        status = data[:status].presence || response.body[:status]
        status = response.status.between?(200, 299) ? "success" : "failure" if status == true
        status = "failure" if status == false
        failure_code = failure_code_for(status, data, response.body)
        log_provider_failure(response, status, failure_code)
        hosted_checkout = checkout_url && data[:checkout_url].present?
        Result.new(
          status: hosted_checkout ? "pending" : (status || "unknown"),
          provider_reference: data[:tx_ref].presence || data[:ref_id].presence || data[:reference],
          failure_code:,
          provider_fee_minor: minor_amount(data[:charge]),
          provider_fee_currency: data[:currency],
          raw_status: hosted_checkout ? "initialized" : status,
          checkout_url: checkout_url ? data[:checkout_url] : nil
        )
      end

      def symbolize(value)
        value.respond_to?(:deep_symbolize_keys) ? value.deep_symbolize_keys : {}
      end

      def failure_code_for(status, data, body)
        return if status.to_s == "success"

        candidate = data[:failure_code].presence || data[:status].presence || body[:status]
        candidate = "provider_rejected" if candidate.blank? || candidate == false
        candidate.to_s.downcase.gsub(/[^a-z0-9]+/, "_").sub(/\A_+|_+\z/, "")[0, 64]
      end

      # Keep provider rejection diagnostics available without logging the raw
      # response, which may contain customer or gateway payload data.
      def log_provider_failure(response, status, failure_code)
        return unless %w[failure failed declined error reversed].include?(status.to_s.downcase)

        message = response.body[:message].to_s.gsub(/\s+/, " ").truncate(200)
        Rails.logger.warn(
          "Chapa provider rejected response status_code=#{response.status} " \
          "status=#{status} failure_code=#{failure_code} message=#{message}"
        )
      end

      def major_amount(amount_minor)
        amount = Integer(amount_minor)
        fail ArgumentError if amount.negative?

        format("%d.%02d", amount / 100, amount % 100)
      end

      def chapa_phone(value)
        phone = value.to_s.strip
        phone = phone.sub(/\A\+?251/, "0")
        phone = "0#{phone}" if phone.match?(/\A[97]\d{8}\z/)
        phone.presence
      end

      def minor_amount(amount)
        return if amount.blank?

        (BigDecimal(amount.to_s) * 100).round(0).to_i
      end

      def secure_equal?(left, right)
        left.present? && left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
      end

      # Rack exposes inbound headers as HTTP_-prefixed CGI keys. Normalize
      # those keys before matching Chapa's documented signature names.
      def normalize_header_key(key)
        key.to_s.sub(/\AHTTP_/i, "").downcase.tr("_", "-")
      end

      def validate_configuration!
        fail ArgumentError unless MODES.include?(@mode)
        fail ArgumentError if @secret_key.blank? || @webhook_secret.blank?

        prefix = @mode == "test" ? "CHASECK_TEST-" : "CHASECK-"
        fail ArgumentError unless @secret_key.start_with?(prefix)
      end
    end
  end
end
