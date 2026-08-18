# frozen_string_literal: true

require "test_helper"

module Ticketing
  class StreamSessionsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include StreamingTestHelpers

    setup do
      @now = Time.current
      build_streaming_ticket(now: @now)
    end

    test "creates a stream session and never serializes its digest" do
      post "/tickets/#{@stream_ticket.id}/stream_sessions",
           params: {
             event_stream_id: @event_stream.id,
             device_id: "ios:9f0f6af3"
           }.to_json,
           headers: user_headers.merge(
             "Content-Type" => "application/json",
             "Idempotency-Key" => "stream-controller:#{@stream_ticket.id}"
           )

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert data.fetch("session_token").present?
      assert_equal "youtube", data.dig("playback_grant", "provider")
      refute_includes data.fetch("session").keys, "session_token_digest"
    end
  end
end
