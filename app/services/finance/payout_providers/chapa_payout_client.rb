# frozen_string_literal: true

require "cgi"
require "json"

module Finance
  module PayoutProviders
    # Chapa V2 payout contract. Provider lifecycle states remain asynchronous;
    # Finance owns durable payout state, allocations, and reconciliation.
    class ChapaPayoutClient
      DEFAULT_API_BASE_URL = "https://api.chapa.global"
      MODES = %w[test live].freeze

      def initialize(secret_key:, mode: "test", api_base_url: DEFAULT_API_BASE_URL, transport: nil)
        @secret_key = secret_key.to_s
        @mode = mode.to_s
        validate_configuration!
        @transport = transport || Core::HttpTransport.new(base_url: api_base_url)
      end

      def payout(**request)
        payload = {
          amount: integer_amount(request.fetch(:amount_minor)),
          currency: currency(request.fetch(:currency)),
          merchant_reference: merchant_reference_for(request),
          account: {
            account_number: required_string(request, :account_number),
            account_name: request[:account_name].to_s.strip.presence,
            bank_slug: required_string(request, :bank_slug),
            bank_name: request[:bank_name].to_s.strip.presence
          }.compact,
          reason: request[:reason].to_s.strip.presence,
          meta: request[:meta].to_h.merge(payout_id: request[:payout_id]).compact
        }.compact

        map_result(post("/v2/payouts", payload, idempotency_key: request[:idempotency_key]))
      end

      def verify_payout(**request)
        reference = request[:provider_reference].presence || request[:merchant_reference].presence ||
          merchant_reference_for(request)
        map_result(get("/v2/payouts/#{CGI.escape(reference.to_s)}/verify"))
      end

      # The reviewed V2 payout documentation does not publish a balance
      # endpoint. Higher-level orchestration must use its internal reserve
      # policy or an explicit no-balance approval rather than guessing a path.
      def available_balance(**)
        nil
      end

      def available_banks(country: nil, **)
        query = country.to_s.strip.upcase.presence
        path = "/v2/payouts/banks"
        path = "#{path}?country=#{CGI.escape(query)}" if query
        response = get(path)
        return unless response.is_a?(Response) && response.status.between?(200, 299)

        bank_items(response.body[:data]).filter_map do |bank|
          attributes = bank.to_h.deep_symbolize_keys
          next if attributes[:bank_slug].blank? || attributes[:is_active] == false

          attributes.slice(:bank_slug, :bank_name, :type, :min_amount, :max_amount,
            :supported_currencies, :is_active).freeze
        end.freeze
      end

      def bank_items(data)
        return data[:items] if data.is_a?(Hash)
        return data if data.is_a?(Array)

        []
      end

      def capabilities
        {
          currencies: %w[ETB USD UGX DJF],
          payouts: { supported: true },
          transfer_verification: true,
          balance_api: { supported: false },
          destination_registration: { supported: false }
        }.freeze
      end

      private

      Response = Data.define(:status, :body)

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

      def map_result(response)
        return response if response.is_a?(Result)
        return Result.unknown(raw_status: "provider_unavailable") if response.status >= 500

        data = response.body[:data].to_h
        status = data[:status].presence || response.body[:status]
        reference = data[:chapa_reference].presence || data[:reference].presence || response.body[:chapa_reference]
        Result.new(
          status:,
          provider_reference: reference,
          failure_code: failure_code_for(status, data, response.body),
          raw_status: status
        )
      end

      def failure_code_for(status, data, body)
        normalized_status = status.to_s.downcase
        return if normalized_status.in?(%w[
          success succeeded completed pending processing
        ])

        candidate = data[:reason].presence || data[:failure_code].presence || body.dig(:error, :code).presence ||
          normalized_status
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

      def integer_amount(amount_minor)
        amount = Integer(amount_minor)
        raise ArgumentError unless amount.positive?

        amount
      end

      def merchant_reference_for(request)
        reference = request[:merchant_reference].to_s.strip.presence
        return reference if reference && reference.length <= Core::ProviderMerchantReference::LENGTH

        Core::ProviderMerchantReference.call(
          provider: "chapa", subject_id: request[:payout_id].presence || "payout",
          idempotency_key: request.fetch(:idempotency_key)
        )
      end

      def validate_configuration!
        raise ArgumentError, I18n.t("finance.payout_providers.errors.invalid_mode", modes: MODES.join(", ")) unless MODES.include?(@mode)
        raise ArgumentError, I18n.t("finance.payout_providers.errors.secret_required") if @secret_key.blank?

        prefix = @mode == "test" ? "CHAPA_TEST_" : "CHAPA_LIVE_"
        raise ArgumentError, I18n.t("finance.payout_providers.errors.secret_prefix", mode: @mode, prefix:) unless @secret_key.start_with?(prefix)
      end
    end
  end
end
