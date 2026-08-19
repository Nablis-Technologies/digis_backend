# frozen_string_literal: true

require "test_helper"

module Streaming
  module Sessions
    class CreateTest < ActiveSupport::TestCase
      include StreamingTestHelpers

      setup do
        @now = Time.current
        build_streaming_ticket(now: @now, max_concurrent_devices: 1)
      end

      test "creates one short-lived session for an authorized current holder" do
        result = Create.call(
          ticket: @stream_ticket,
          event_stream: @event_stream,
          user: @stream_buyer,
          device_id: "ios:9f0f6af3",
          now: @now,
          idempotency_key: "stream:#{@stream_ticket.id}:ios:9f0f6af3"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "active", result.value.session.status
        assert result.value.session_token.present?
        assert_not_equal result.value.session_token, result.value.session.session_token_digest
        assert_equal "youtube", result.value.playback_grant.provider
        assert_equal "embed", result.value.playback_grant.playback_type
        assert_equal @event_stream.provider_playback_id, result.value.playback_grant.embed_id
        assert_nil result.value.playback_grant.token
      end

      test "rejects a second distinct device after the concurrent-device limit" do
        first = Create.call(
          ticket: @stream_ticket, event_stream: @event_stream, user: @stream_buyer,
          device_id: "ios:first", now: @now,
          idempotency_key: "stream:first:#{@stream_ticket.id}"
        )
        second = Create.call(
          ticket: @stream_ticket, event_stream: @event_stream, user: @stream_buyer,
          device_id: "ios:second", now: @now,
          idempotency_key: "stream:second:#{@stream_ticket.id}"
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "stream_device_limit_reached", second.error.code
      end

      test "rejects a user who is not the current ticket holder" do
        result = Create.call(
          ticket: @stream_ticket, event_stream: @event_stream, user: core_users(:support),
          device_id: "ios:outsider", now: @now,
          idempotency_key: "stream:outsider:#{@stream_ticket.id}"
        )

        assert_predicate result, :failure?
        assert_equal "stream_not_authorized", result.error.code
      end

      test "authorizes replay only inside the configured replay window" do
        replay_now = Time.current
        build_streaming_ticket(
          now: replay_now,
          stream_status: "ended",
          replay_enabled: true,
          replay_available_until: replay_now + 30.minutes
        )

        result = Create.call(
          ticket: @stream_ticket, event_stream: @event_stream, user: @stream_buyer,
          device_id: "ios:replay", now: replay_now,
          idempotency_key: "stream:replay:#{@stream_ticket.id}"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal true, result.value.playback_grant.expires_at <= @event_stream.replay_available_until
      end

      test "rejects playback after a live stream when replay is disabled" do
        later = @event_stream.live_until + 1.minute
        result = Create.call(
          ticket: @stream_ticket, event_stream: @event_stream, user: @stream_buyer,
          device_id: "ios:late", now: later,
          idempotency_key: "stream:late:#{@stream_ticket.id}"
        )

        assert_predicate result, :failure?
        assert_equal "stream_window_closed", result.error.code
      end

      test "rejects a provider that is disabled by configuration" do
        original = Rails.application.config.x.streaming.enabled_providers
        Rails.application.config.x.streaming.enabled_providers = []

        result = Create.call(
          ticket: @stream_ticket, event_stream: @event_stream, user: @stream_buyer,
          device_id: "ios:disabled", now: @now,
          idempotency_key: "stream:disabled:#{@stream_ticket.id}"
        )

        assert_predicate result, :failure?
        assert_equal "streaming_playback_unavailable", result.error.code
      ensure
        Rails.application.config.x.streaming.enabled_providers = original
      end
    end
  end
end
