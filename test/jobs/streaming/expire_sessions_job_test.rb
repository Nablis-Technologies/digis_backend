# frozen_string_literal: true

require "test_helper"

module Streaming
  class ExpireSessionsJobTest < ActiveJob::TestCase
    include StreamingTestHelpers

    setup do
      @now = Time.current.change(usec: 0)
      build_streaming_ticket(now: @now)
      @expired_session = create_stream_session(expires_at: @now + 1.hour)
      @active_session = create_stream_session(device_id: "ios:active", expires_at: @now + 2.hours)
    end

    test "expires due sessions without extending active sessions" do
      ExpireSessionsJob.perform_now(now: @now + 1.hour + 1.minute)

      assert_equal "expired", @expired_session.reload.status
      assert_equal "active", @active_session.reload.status
      assert_equal @now + 1.hour, @expired_session.expires_at
    end

    test "replaying expiry is idempotent" do
      ExpireSessionsJob.perform_now(now: @now + 1.hour + 1.minute)

      assert_nothing_raised { ExpireSessionsJob.perform_now(now: @now + 1.hour + 1.minute) }
      assert_equal "expired", @expired_session.reload.status
    end
  end
end
