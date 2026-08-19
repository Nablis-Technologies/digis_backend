# frozen_string_literal: true

require "bigdecimal"
require "json"
require "net/http"
require "uri"

module Payments
  module Providers
    # Small, injectable HTTPS transport for Chapa. It returns parsed response
    # data without retaining request headers or provider payloads after the
    # call, so the client can normalize only the evidence Orders needs.
    class ChapaHttpTransport
      Response = Data.define(:status, :body)

      def initialize(base_url:, timeout_seconds: 10)
        @base_url = base_url.to_s.chomp("/")
        @timeout_seconds = timeout_seconds.to_i
      end

      def call(method:, path:, headers:, body: nil)
        uri = URI.join("#{@base_url}/", path.to_s.delete_prefix("/"))
        request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
        headers.each { |key, value| request[key] = value }
        request.body = body if body

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @timeout_seconds
        http.read_timeout = @timeout_seconds
        response = http.request(request)
        Response.new(status: response.code.to_i, body: parse_body(response.body))
      end

      private

      def parse_body(body)
        JSON.parse(body.presence || "{}", decimal_class: BigDecimal)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
