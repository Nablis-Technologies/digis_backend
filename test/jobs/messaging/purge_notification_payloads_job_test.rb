# frozen_string_literal: true

require "test_helper"

module Messaging
  class PurgeNotificationPayloadsJobTest < ActiveJob::TestCase
    setup do
      create_messaging_policy
      @notification = create_messaging_notification(type: "payment_succeeded")
      @notification.update_columns(
        retain_until: 1.hour.ago,
        created_at: 2.hours.ago,
        updated_at: 2.hours.ago
      )
    end

    test "erases expired payloads but preserves the notification identity" do
      Messaging::PurgeNotificationPayloadsJob.perform_now

      @notification.reload
      assert_equal({}, @notification.data)
      assert_not_nil @notification.erased_at
      assert_equal "policy_expiry", @notification.erasure_reason
      assert_equal "payment_succeeded", @notification.notification_type
      assert Messaging::Notification.exists?(@notification.id)
    end

    test "does not erase a notification under an active retention hold" do
      Core::DataRetentionHold.create!(
        user: @notification.user,
        category: "messaging_notification",
        reason_code: "legal_hold",
        starts_at: 1.minute.ago,
        idempotency_key: "messaging-hold-#{SecureRandom.uuid}",
        placed_by: core_users(:super_admin)
      )

      Messaging::PurgeNotificationPayloadsJob.perform_now

      assert_not @notification.reload.erased?
    end

    test "does not hold one transaction open for the entire candidate page" do
      second = create_messaging_notification(type: "payment_succeeded", dedupe_key: SecureRandom.uuid)
      states = []
      baseline_transactions = Messaging::Notification.connection.open_transactions
      job = Messaging::PurgeNotificationPayloadsJob.new
      ids = [ @notification.id, second.id ]
      job.define_singleton_method(:candidate_ids) { |_limit, _at| ids }
      job.define_singleton_method(:retention_scopes) { |_ids| {} }
      job.define_singleton_method(:process) do |notification_id, _at, _summary|
        states << [ notification_id, Messaging::Notification.connection.open_transactions ]
      end

      job.perform

      assert_equal ids, states.map(&:first)
      assert_equal [ baseline_transactions, baseline_transactions ], states.map(&:last)
    end
  end
end
