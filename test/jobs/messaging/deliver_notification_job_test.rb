# frozen_string_literal: true

require "test_helper"

module Messaging
  class DeliverNotificationJobTest < ActiveJob::TestCase
    setup do
      create_messaging_policy
      @notification = create_messaging_notification
      @delivery = create_messaging_delivery(notification: @notification)
    end

    test "enqueues only the delivery id" do
      assert_enqueued_with(job: Messaging::DeliverNotificationJob, args: [ @delivery.id ]) do
        Messaging::DeliverNotificationJob.perform_later(@delivery.id)
      end
    end

    test "delivers a queued row" do
      Messaging::DeliverNotificationJob.perform_now(@delivery.id)

      assert_equal "delivered", @delivery.reload.status
    end
  end
end
