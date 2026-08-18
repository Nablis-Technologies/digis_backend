# frozen_string_literal: true

require "test_helper"

module Streaming
  module Providers
    class YouTubeAdapterTest < ActiveSupport::TestCase
      include StreamingTestHelpers
      include Streaming::ProviderAdapterContract

      setup do
        @now = Time.current
        build_streaming_ticket(now: @now)
        @stream_session = create_stream_session(expires_at: @now + 10.minutes)
        @window = Streaming::Window.new(
          opens_at: @now - 1.minute,
          closes_at: @now + 5.minutes,
          replay: false
        )
      end

      test "returns a YouTube embed grant without a provider token" do
        grant = YouTubeAdapter.new.playback_grant(session: @stream_session, window: @window)

        assert_equal "youtube", grant.provider
        assert_equal "embed", grant.playback_type
        assert_equal @event_stream.provider_playback_id, grant.embed_id
        assert_nil grant.token
      end

      test "rejects signed protection because YouTube cannot enforce it" do
        @event_stream.update!(access_protection: "signed")

        assert_raises(InvalidConfiguration) do
          YouTubeAdapter.new.playback_grant(session: @stream_session, window: @window)
        end
      end

      test "rejects a missing playback identifier" do
        @event_stream.update_column(:provider_playback_id, nil)

        assert_raises(PlaybackUnavailable) do
          YouTubeAdapter.new.playback_grant(session: @stream_session, window: @window)
        end
      end

      private

      def adapter_under_test = YouTubeAdapter.new
      def stream_session = @stream_session
      def stream_window = @window
    end
  end
end
