# frozen_string_literal: true

require "test_helper"

module Messaging
  class ProcessNotificationsJobTest < ActiveJob::TestCase
    setup do
      create_messaging_policy
      @notification = create_messaging_notification(type: "payment_succeeded")
      @due = create_messaging_delivery(notification: @notification)
      @future = create_messaging_delivery(notification: @notification, channel: "email")
      @future.update!(scheduled_at: 1.hour.from_now)
    end

    test "enqueues only due non-terminal deliveries in a bounded batch" do
      assert_enqueued_with(job: Messaging::DeliverNotificationJob, args: [ @due.id ]) do
        Messaging::ProcessNotificationsJob.perform_now
      end

      assert_equal "pending", @due.reload.status
      assert_equal "pending", @future.reload.status
    end

    test "one enqueue failure does not starve the rest of the due page" do
      second = create_messaging_delivery(notification: @notification, channel: "sms")
      attempted = []
      original = Messaging::DeliverNotificationJob.method(:perform_later)
      Messaging::DeliverNotificationJob.define_singleton_method(:perform_later) do |delivery_id|
        attempted << delivery_id
        raise "simulated enqueue failure" if delivery_id == @due.id
      end

      begin
        Messaging::ProcessNotificationsJob.perform_now
      ensure
        Messaging::DeliverNotificationJob.define_singleton_method(:perform_later, original)
      end

      assert_equal [ @due.id, second.id ].sort, attempted.sort
    end

    test "does not enqueue a fresh pending delivery lease twice" do
      assert_enqueued_jobs 1 do
        Messaging::ProcessNotificationsJob.perform_now
      end
      clear_enqueued_jobs

      assert_no_enqueued_jobs do
        Messaging::ProcessNotificationsJob.perform_now
      end
    end

    test "reclaims a stale enqueue lease" do
      @due.update!(enqueue_claimed_at: 10.minutes.ago)

      assert_enqueued_with(job: Messaging::DeliverNotificationJob, args: [ @due.id ]) do
        Messaging::ProcessNotificationsJob.perform_now
      end
    end
  end
end
