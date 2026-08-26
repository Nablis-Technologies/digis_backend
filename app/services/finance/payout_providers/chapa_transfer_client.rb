# frozen_string_literal: true

require "bigdecimal"
require "cgi"
require "json"
require "net/http"

module Finance
  module PayoutProviders
    # Owns Chapa's bank-transfer HTTP contract without mixing it into the
    # pay-in/refund client. Finance receives only normalized payout results.
    class ChapaTransferClient
      DEFAULT_API_BASE_URL = "https://api.chapa.co/v1"
      MODES = %w[test live].freeze

      def initialize(secret_key:, mode: "test", api_base_url: DEFAULT_API_BASE_URL, transport: nil)
        @secret_key = secret_key.to_s
        @mode = mode.to_s
        validate_configuration!
        @transport = transport || Payments::Providers::ChapaHttpTransport.new(base_url: api_base_url)
      end

      def payout(**request)
        payload = {
          account_number: required_string(request, :account_number),
          account_name: request[:account_name].to_s.strip.presence,
          amount: major_amount(request.fetch(:amount_minor)),
          bank_code: Integer(request.fetch(:bank_code)),
          currency: currency(request.fetch(:currency)),
          reference: required_string(request, :idempotency_key)
        }.compact

        map_result(post("/transfers", payload))
      end

      def verify_payout(**request)
        reference = request[:provider_reference].presence || request.fetch(:idempotency_key)
        map_result(get("/transfers/verify/#{CGI.escape(reference.to_s)}"))
      end

      def available_balance(**request)
        requested_currency = currency(request.fetch(:currency))
        response = get("/balances/#{requested_currency.downcase}")
        return unless response.is_a?(Response) && response.status.between?(200, 299)

        balance = Array(response.body[:data]).find do |entry|
          entry[:currency].to_s.upcase == requested_currency
        end
        return unless balance

        { amount_minor: minor_amount(balance[:available_balance]), currency: balance[:currency].to_s.upcase }.freeze
      end

      def available_banks
        response = get("/banks")
        return unless response.is_a?(Response) && response.status.between?(200, 299)

        Array(response.body[:data]).filter_map do |bank|
          identifier = bank.to_h.deep_symbolize_keys[:id] || bank.to_h.deep_symbolize_keys[:bank_code]
          Integer(identifier, exception: false)
        end.uniq.freeze
      end

      private

      Response = Data.define(:status, :body)

      def get(path) = request(:get, path)

      def post(path, payload) = request(:post, path, JSON.generate(payload), "application/json")

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

      def map_result(response)
        return response if response.is_a?(Result)
        return Result.unknown(raw_status: "provider_unavailable") if response.status >= 500

        data = response.body[:data].to_h
        status = data[:status].presence || response.body[:status]
        status = response.status.between?(200, 299) ? "success" : "failure" if status == true
        status = "failure" if status == false
        Result.new(
          status: status || (response.status.between?(200, 299) ? "unknown" : "failure"),
          provider_reference: data[:reference].presence || data[:tx_ref].presence || data[:ref_id].presence ||
            response.body[:reference],
          failure_code: failure_code_for(status, data, response.body),
          raw_status: status
        )
      end

      def failure_code_for(status, data, body)
        return if status.to_s == "success"

        candidate = data[:failure_code].presence || data[:status].presence || body[:status]
        candidate = "provider_rejected" if candidate.blank? || candidate == false
        candidate.to_s.downcase.gsub(/[^a-z0-9]+/, "_").sub(/\A_+|_+\z/, "")[0, 64]
      end

      def symbolize(value)
        value.respond_to?(:deep_symbolize_keys) ? value.deep_symbolize_keys : {}
      end

      def required_string(request, key)
        value = request[key].to_s.strip
        raise ArgumentError if value.blank?

        value
      end

      def currency(value)
        normalized = value.to_s.strip.upcase
        raise ArgumentError unless normalized.match?(/\A[A-Z]{3}\z/)

        normalized
      end

      def major_amount(amount_minor)
        amount = Integer(amount_minor)
        raise ArgumentError unless amount.positive?

        format("%d.%02d", amount / 100, amount % 100)
      end

      def minor_amount(amount)
        return if amount.blank?

        (BigDecimal(amount.to_s) * 100).round(0).to_i
      end

      def validate_configuration!
        raise ArgumentError unless MODES.include?(@mode)

        prefix = @mode == "test" ? "CHASECK_TEST-" : "CHASECK-"
        raise ArgumentError unless @secret_key.start_with?(prefix)
      end
    end
  end
end
