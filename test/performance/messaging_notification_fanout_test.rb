# frozen_string_literal: true

require "test_helper"

module Messaging
  class MessagingNotificationFanoutTest < ActiveSupport::TestCase
    test "loads one bounded schedule audience page without repeated recipient queries" do
      event = events_events(:ready_listing)
      outbox = Core::Outbox::Publish.call(
        topic: "events", event_type: "events.schedule_changed", aggregate: event,
        payload: { event_id: event.id, version: 1, event_date_ids: [] },
        idempotency_key: "fanout-performance-#{SecureRandom.uuid}"
      ).value
      calls = 0
      original = Messaging::PublishNotification.method(:call)
      Messaging::PublishNotification.define_singleton_method(:call) do |**|
        calls += 1
        Core::BaseService::Result.success(:published)
      end

      begin
        Messaging::FanoutNotificationJob.perform_now(outbox.id)
      ensure
        Messaging::PublishNotification.define_singleton_method(:call, original)
      end

      assert_operator calls, :<=, Messaging::FanoutNotificationJob::PAGE_SIZE
    end

    test "preserves every UUID-string recipient across bounded cursor pages" do
      first_source = (1..110).map { |id| format("00000000-0000-0000-0000-%012d", id) }
      second_source = (111..220).map { |id| format("00000000-0000-0000-0000-%012d", id) }
      sources = [ first_source, second_source ]
      cursor = nil
      delivered = []
      job = Messaging::FanoutNotificationJob.new

      loop do
        bounded = sources.map do |source|
          source.select { |id| cursor.nil? || id > cursor }.first(Messaging::FanoutNotificationJob::PAGE_SIZE + 1)
        end
        ids = job.send(:merge_recipient_ids, *bounded)
        page = ids.first(Messaging::FanoutNotificationJob::PAGE_SIZE)
        break if page.empty?

        delivered.concat(page)
        break if ids.length <= page.length

        cursor = page.last
      end

      assert_equal sources.flatten.sort, delivered
    end
  end
end
