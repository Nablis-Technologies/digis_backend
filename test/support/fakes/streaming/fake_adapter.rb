# frozen_string_literal: true

module Streaming
  module Fakes
    class FakeAdapter < Streaming::Providers::BaseAdapter
      def initialize(provider: "fake")
        @provider = provider
      end

      def playback_grant(session:, window:)
        Streaming::PlaybackGrant.new(
          provider: @provider,
          playback_type: "hls",
          playback_url: "https://stream.test/#{session.id}.m3u8",
          embed_id: nil,
          token: "fake-playback-token",
          expires_at: [ window.closes_at, session.expires_at ].min
        )
      end

      def revoke_playback(session:)
        true
      end

      def supported_access_protections
        %w[public soft_gated signed]
      end

      def validate_configuration!(_event_stream)
        true
      end
    end
  end
end
