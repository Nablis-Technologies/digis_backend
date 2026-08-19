# frozen_string_literal: true

require "test_helper"

module Streaming
  module Sessions
    class RefreshTest < ActiveSupport::TestCase
      include StreamingTestHelpers

      setup do
        @now = Time.current.change(usec: 0)
        build_streaming_ticket(now: @now)
        @session_token = SecureRandom.urlsafe_base64(32)
        @session = Ticketing::StreamSession.create!(
          ticket: @stream_ticket,
          event_stream: @event_stream,
          user: @stream_buyer,
          device_id: "ios:9f0f6af3",
          session_token_digest: Core::KeyedDigest.digest(
            namespace: "streaming-session", value: @session_token
          ),
          status: "active",
          expires_at: @now + 2.minutes
        )
      end

      test "refreshes an active session and returns only a new playback grant" do
        result = Refresh.call(
          session: @session,
          session_token: @session_token,
          user: @stream_buyer,
          now: @now,
          idempotency_key: "stream-refresh:#{@session.id}"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal @now, result.value.session.last_seen_at
        assert_operator result.value.session.expires_at, :>, @now + 2.minutes
        assert_equal "youtube", result.value.playback_grant.provider
      end

      test "rejects a wrong session token" do
        result = Refresh.call(
          session: @session,
          session_token: "wrong-token",
          user: @stream_buyer,
          now: @now,
          idempotency_key: "stream-refresh:wrong-token"
        )

        assert_predicate result, :failure?
        assert_equal "stream_session_invalid", result.error.code
      end

      test "uses the injected clock when expiring a session" do
        result = Refresh.call(
          session: @session,
          session_token: @session_token,
          user: @stream_buyer,
          now: @now + 3.minutes,
          idempotency_key: "stream-refresh:future-expiry:#{@session.id}"
        )

        assert_predicate result, :failure?
        assert_equal "stream_session_expired", result.error.code
        assert_equal "expired", @session.reload.status
      end

      test "revokes a session idempotently" do
        first = Revoke.call(
          session: @session, session_token: @session_token, user: @stream_buyer, now: @now,
          idempotency_key: "stream-revoke:#{@session.id}"
        )
        second = Revoke.call(
          session: @session.reload, session_token: @session_token, user: @stream_buyer, now: @now,
          idempotency_key: "stream-revoke:#{@session.id}"
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal "revoked", second.value.status
        assert_equal first.value.revoked_at, second.value.revoked_at
      end
    end
  end
end
