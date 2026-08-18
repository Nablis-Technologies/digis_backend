# frozen_string_literal: true

module Streaming
  module ProviderAdapterContract
    extend ActiveSupport::Concern

    included do
      test "returns a bounded provider-neutral playback grant" do
        grant = adapter_under_test.playback_grant(session: stream_session, window: stream_window)

        assert_instance_of Streaming::PlaybackGrant, grant
        assert_includes adapter_under_test.supported_access_protections,
          stream_session.event_stream.access_protection
        assert_operator grant.expires_at, :<=, stream_session.expires_at
        assert_operator grant.expires_at, :<=, stream_window.closes_at
      end

      test "revocation is retry safe" do
        first = adapter_under_test.revoke_playback(session: stream_session)
        second = adapter_under_test.revoke_playback(session: stream_session)

        assert_equal first, second
      end
    end

    private

    def adapter_under_test = raise(NotImplementedError)
    def stream_session = raise(NotImplementedError)
    def stream_window = raise(NotImplementedError)
  end
end
