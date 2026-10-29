# frozen_string_literal: true

require "json"
require "openssl"
require "test_helper"

module Messaging
  module Campaigns
    module Suppressions
      class SuppressionsTest < ActiveSupport::TestCase
        setup do
          @organization = organizations_organizations(:two)
          @actor = core_users(:super_admin)
          @phone = "251911123456"
          @digest = phone_digest(@phone)
        end

        test "records global and organization suppressions by channel" do
          global = Record.call(
            channel: "sms", channel_address_digest: @digest, source: "unsubscribe",
            reason: "stop", idempotency_key: "global-suppression-1"
          )
          scoped = Record.call(
            organization: @organization, channel: "email", channel_address_digest: @digest,
            source: "organizer", reason: "do not contact", idempotency_key: "org-suppression-1"
          )

          assert global.success?
          assert scoped.success?
          assert_nil global.value.organization_id
          assert_equal @organization.id, scoped.value.organization_id
          assert_equal 2, CampaignSuppression.where(channel_address_digest: @digest).count
        end

        test "replays the same suppression without creating another row" do
          operation = -> {
            Record.call(
              organization: @organization,
              channel: "sms",
              channel_address_digest: @digest,
              source: "unsubscribe",
              reason: "stop",
              idempotency_key: "suppression-replay"
            )
          }

          assert_idempotent(operation, counter: -> { CampaignSuppression.count })
        end

        test "rejects reuse of an idempotency key for another address" do
          Record.call(
            organization: @organization, channel: "sms", channel_address_digest: @digest,
            source: "unsubscribe", reason: "stop", idempotency_key: "suppression-conflict"
          )
          other_digest = phone_digest("251911654321")

          result = Record.call(
            organization: @organization, channel: "sms", channel_address_digest: other_digest,
            source: "unsubscribe", reason: "stop", idempotency_key: "suppression-conflict"
          )

          assert_equal "idempotency_conflict", result.error.code
        end

        test "processes a signed SMS STOP event once and ignores non-opt-out messages" do
          secret = "inbound-secret"
          adapter = FakeInboundAdapter.new(secret)
          Providers::InboundRegistry.configure.register(provider: "fake_sms", adapter:)
          payload = { external_event_id: "evt-stop-1", phone_number: "+251911123456", message: " STOP " }
          raw_body = JSON.generate(payload)
          headers = { "X-Provider-Signature" => OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body) }

          first = ProcessInbound.call(provider: "fake_sms", channel: "sms", raw_body:, headers:)
          replay = ProcessInbound.call(provider: "fake_sms", channel: "sms", raw_body:, headers:)

          assert first.success?
          assert replay.success?
          assert_equal 1, CampaignInboundEvent.where(provider: "fake_sms", external_event_id: "evt-stop-1").count
          assert_equal 1, CampaignSuppression.where(channel: "sms", channel_address_digest: @digest).count

          payload[:external_event_id] = "evt-info-1"
          payload[:message] = "hello"
          raw_body = JSON.generate(payload)
          headers["X-Provider-Signature"] = OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
          ignored = ProcessInbound.call(provider: "fake_sms", channel: "sms", raw_body:, headers:)

          assert ignored.success?
          assert_equal "ignored", ignored.value.status
          assert_equal 1, CampaignSuppression.where(channel: "sms", channel_address_digest: @digest).count
        end

        test "rejects an invalid provider signature without creating suppression" do
          adapter = FakeInboundAdapter.new("inbound-secret")
          Providers::InboundRegistry.configure.register(provider: "bad_sms", adapter:)
          raw_body = JSON.generate(external_event_id: "evt-bad", phone_number: "+251911123456", message: "STOP")

          result = ProcessInbound.call(
            provider: "bad_sms", channel: "sms", raw_body:,
            headers: { "X-Provider-Signature" => "bad" }
          )

          assert_equal "invalid_provider_signature", result.error.code
          assert_equal :unauthorized, result.error.status_code
          assert_not CampaignSuppression.exists?(channel_address_digest: @digest)
        end

        test "uses provider-defined stop words" do
          secret = "provider-stop-secret"
          adapter = FakeInboundAdapter.new(secret)
          adapter.define_singleton_method(:stop_words) { [ "arret" ] }
          Providers::InboundRegistry.configure.register(provider: "provider_words", adapter:)
          raw_body = JSON.generate(
            external_event_id: "evt-provider-stop", phone_number: "+251911123456", message: " ARRET "
          )

          result = ProcessInbound.call(
            provider: "provider_words", channel: "sms", raw_body:,
            headers: { "X-Provider-Signature" => OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body) }
          )

          assert result.success?, result.error&.message
          assert_equal 1, CampaignSuppression.where(channel: "sms", channel_address_digest: @digest).count
        end

        private

        def phone_digest(phone)
          Core::KeyedDigest.digest(namespace: "messaging-campaign-contact-phone", value: phone)
        end

        class FakeInboundAdapter < Providers::InboundAdapter
          def initialize(secret)
            @secret = secret
          end

          def verify_inbound(raw_body:, headers:)
            expected = OpenSSL::HMAC.hexdigest("SHA256", @secret, raw_body)
            ActiveSupport::SecurityUtils.secure_compare(headers.fetch("X-Provider-Signature"), expected)
          end

          def parse_inbound(raw_body:, headers:)
            JSON.parse(raw_body).symbolize_keys
          end
        end
      end
    end
  end
end
