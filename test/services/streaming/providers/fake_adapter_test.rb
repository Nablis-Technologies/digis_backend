# frozen_string_literal: true

require "test_helper"

module Streaming
  module Providers
    class FakeAdapterTest < ActiveSupport::TestCase
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

      private

      def adapter_under_test = Streaming::Fakes::FakeAdapter.new
      def stream_session = @stream_session
      def stream_window = @window
    end
  end
end
