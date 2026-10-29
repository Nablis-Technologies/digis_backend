# frozen_string_literal: true

require "digest"

module Messaging
  module Campaigns
    module Suppressions
      # Verifies and records provider opt-out events exactly once.
      class ProcessInbound < Core::BaseService
        def initialize(provider:, channel:, raw_body:, headers:)
          @provider = provider.to_s.strip.downcase
          @channel = channel.to_s.strip.downcase
          @raw_body = raw_body.to_s
          @headers = headers.to_h
        end

        def call
          adapter = Providers::InboundRegistry.configure.fetch(provider: @provider)
          return failure(error(:inbound_provider_unavailable, status: :unprocessable_entity)) unless adapter
          return failure(error(:invalid_provider_signature, status: :unauthorized)) unless verified?(adapter)

          payload = adapter.parse_inbound(raw_body: @raw_body, headers: @headers).to_h.stringify_keys
          event = find_or_create_event(payload)
          return success(event) unless event.status == "received"

          if stop_message?(payload, adapter)
            address = payload["phone_number"] || payload["email"] || payload["address"]
            Record.call(
              channel: @channel,
              channel_address_digest: digest_for(normalized_address(address)),
              source: "provider_inbound",
              reason: "#{@provider}:#{payload.fetch("message").to_s.strip.downcase}",
              idempotency_key: "messaging-inbound-#{@provider}-#{event.external_event_id}"
            ).tap { |result| raise result.error if result.failure? }
            event.update!(status: "processed", processed_at: Time.current)
          else
            event.update!(status: "ignored", processed_at: Time.current)
          end
          success(event)
        rescue KeyError, JSON::ParserError, ArgumentError
          failure(error(:inbound_payload_invalid))
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:inbound_payload_invalid, message: exception.message))
        end

        private

        attr_reader :provider, :channel, :raw_body, :headers

        def find_or_create_event(payload)
          CampaignInboundEvent.create!(
            provider:,
            external_event_id: payload.fetch("external_event_id"),
            payload_digest: Digest::SHA256.hexdigest(raw_body),
            status: "received",
            received_at: Time.current
          )
        rescue ActiveRecord::RecordNotUnique
          CampaignInboundEvent.find_by!(provider:, external_event_id: payload.fetch("external_event_id"))
        end

        def verified?(adapter)
          adapter.verify_inbound(raw_body:, headers:)
        rescue ArgumentError, KeyError
          false
        end

        def stop_message?(payload, adapter)
          words = if adapter.respond_to?(:stop_words)
            adapter.stop_words
          else
            Providers::InboundAdapter::DEFAULT_STOP_WORDS
          end
          Array(words).map { |word| word.to_s.strip.downcase }.include?(payload.fetch("message").to_s.strip.downcase)
        end

        def normalized_address(value)
          ChannelAddress.normalize(channel:, value:)
        end

        def digest_for(address)
          raise ArgumentError if address.blank?

          ChannelAddress.digest(channel:, value: address)
        end

        def error(key, message: nil, status: :unprocessable_entity)
          Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
        end
      end
    end
  end
end
