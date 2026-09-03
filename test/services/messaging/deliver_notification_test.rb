# frozen_string_literal: true

require "test_helper"

module Messaging
  class DeliverNotificationTest < ActiveSupport::TestCase
    setup do
      create_messaging_policy
      @notification = create_messaging_notification(type: "payment_succeeded")
    end

    test "delivers in-app notifications without a network call" do
      delivery = create_messaging_delivery(notification: @notification)

      result = Messaging::DeliverNotification.call(delivery:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "delivered", delivery.reload.status
      assert_equal "internal", delivery.provider
      assert delivery.delivered_at.present?
    end

    test "missing provider is observable without removing the in-app notification" do
      in_app = create_messaging_delivery(notification: @notification, channel: "in_app")
      email = create_messaging_delivery(notification: @notification, channel: "email")

      assert_predicate Messaging::DeliverNotification.call(delivery: in_app), :success?
      result = Messaging::DeliverNotification.call(delivery: email)

      assert_predicate result, :success?, result.error&.message
      assert_equal "unavailable", email.reload.status
      assert_equal "delivered", in_app.reload.status
    end

    test "a terminal delivery is a replay no-op" do
      delivery = create_messaging_delivery(notification: @notification, status: "delivered")
      delivery.update!(delivered_at: 1.minute.ago)
      delivered_at = delivery.delivered_at

      result = Messaging::DeliverNotification.call(delivery:)

      assert_predicate result, :success?
      assert_equal delivered_at, delivery.reload.delivered_at
    end

    test "does not deliver before the notification schedule is due" do
      delivery = create_messaging_delivery(notification: @notification)
      delivery.update!(scheduled_at: 1.hour.from_now)

      result = Messaging::DeliverNotification.call(delivery:)

      assert_predicate result, :success?
      assert_equal "pending", delivery.reload.status
      assert_nil delivery.claimed_at
    end

    test "returns a claim-lost failure when finalization updates no row" do
      delivery = create_messaging_delivery(notification: @notification)
      relation = Object.new
      relation.define_singleton_method(:update_all) { |_attributes| 0 }

      Messaging::NotificationDelivery.expects(:where).returns(relation)
      result = Messaging::DeliverNotification.call(delivery:)

      assert_predicate result, :failure?
      assert_equal "delivery_claim_lost", result.error.code
    end

    test "maps a permanent adapter failure without leaking raw details" do
      adapter = Class.new do
        def deliver(**)
          Messaging::Providers::DeliveryResult.failed(
            provider: "fake", failure_code: "rejected", failure_detail: "Authorization: secret"
          )
        end
      end.new
      registry = Rails.application.config.x.messaging_provider_registry
      previous = registry.fetch(channel: "email")
      registry.register(channel: "email", adapter:)
      delivery = create_messaging_delivery(notification: @notification, channel: "email")

      result = Messaging::DeliverNotification.call(delivery:)

      assert_predicate result, :success?
      assert_equal "failed", delivery.reload.status
      assert_equal "rejected", delivery.failure_code
      refute_includes delivery.failure_detail.to_s, "secret"
    ensure
      if previous
        registry.register(channel: "email", adapter: previous)
      else
        registry.unregister(channel: "email") if registry
      end
    end
  end
end
