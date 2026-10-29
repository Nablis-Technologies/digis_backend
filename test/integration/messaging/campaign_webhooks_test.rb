# frozen_string_literal: true

require "json"
require "openssl"
require "test_helper"

module Messaging
  class CampaignWebhooksTest < ActionDispatch::IntegrationTest
    setup do
      @secret = "integration-inbound-secret"
      Providers::InboundRegistry.configure.register(
        provider: "integration_sms", adapter: FakeInboundAdapter.new(@secret)
      )
      @digest = Core::KeyedDigest.digest(
        namespace: "messaging-campaign-contact-phone", value: "251911123456"
      )
    end

    test "rejects an invalid provider signature without creating suppression" do
      post "/messaging/webhooks/integration_sms/inbound",
        params: JSON.generate(external_event_id: "http-invalid", phone_number: "+251911123456", message: "STOP"),
        headers: { "X-Provider-Signature" => "bad", "Content-Type" => "application/json" }

      assert_response :unauthorized
      assert_equal "invalid_provider_signature", JSON.parse(response.body).fetch("code")
      assert_not CampaignSuppression.exists?(channel_address_digest: @digest)
    end

    test "records a signed STOP webhook idempotently" do
      payload = JSON.generate(external_event_id: "http-stop", phone_number: "+251911123456", message: "STOP")
      signature = OpenSSL::HMAC.hexdigest("SHA256", @secret, payload)
      headers = { "X-Provider-Signature" => signature, "Content-Type" => "application/json" }

      2.times do
        post "/messaging/webhooks/integration_sms/inbound", params: payload, headers: headers
        assert_response :accepted
      end

      assert_equal 1, CampaignInboundEvent.where(provider: "integration_sms", external_event_id: "http-stop").count
      assert_equal 1, CampaignSuppression.where(channel: "sms", channel_address_digest: @digest).count
    end

    class FakeInboundAdapter < Providers::InboundAdapter
      def initialize(secret)
        @secret = secret
      end

      def verify_inbound(raw_body:, headers:)
        signature = headers["X-Provider-Signature"] || headers["HTTP_X_PROVIDER_SIGNATURE"]
        return false if signature.blank? || signature.bytesize != 64

        ActiveSupport::SecurityUtils.secure_compare(
          signature, OpenSSL::HMAC.hexdigest("SHA256", @secret, raw_body)
        )
      end

      def parse_inbound(raw_body:, headers:)
        JSON.parse(raw_body)
      end
    end
  end
end
