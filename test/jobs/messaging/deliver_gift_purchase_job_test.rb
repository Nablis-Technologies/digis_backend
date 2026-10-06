# frozen_string_literal: true

require "test_helper"

module Messaging
  class DeliverGiftPurchaseJobTest < ActiveJob::TestCase
    include Orders::GiftPurchaseTestHelpers

    setup do
      setup_gift_purchase_context
      @messages = []
      @previous_registry = Rails.application.config.x.messaging_provider_registry
      @previous_short_links = Rails.application.config.x.short_links.to_h
      @previous_public_app_url = Rails.application.config.x.public_app_url

      configure_provider
    end

    teardown do
      Rails.application.config.x.messaging_provider_registry = @previous_registry
      @previous_short_links.each { |key, value| Rails.application.config.x.short_links.public_send("#{key}=", value) }
      Rails.application.config.x.public_app_url = @previous_public_app_url
    end

    test "sends the bearer link and private note only after payment is ready" do
      @gift_purchase.update!(status: "pending_payment", ready_at: nil)

      assert_nothing_raised { DeliverGiftPurchaseJob.perform_now(@gift_purchase.id) }

      assert_empty @messages
      assert_equal "pending", @gift_purchase.reload.delivery_status
    end

    test "sends the gift link in the fragment with stable channel idempotency keys" do
      DeliverGiftPurchaseJob.perform_now(@gift_purchase.id)

      assert_equal %i[sms email], @messages.map(&:first)
      @messages.each do |_channel, attributes|
        body = attributes.fetch(:body)
        assert_includes body, @gift_purchase.note
        url = URI.parse(body.match(%r{https://[^\s]+}).to_s)
        assert_equal "/", url.path
        assert_nil url.query
        assert_match(/gift\/#{@gift_purchase.id}\?token=#{Regexp.escape(ERB::Util.url_encode(@gift_token))}/, url.fragment)
      end
      assert_equal "orders-gift-sms-#{@gift_purchase.id}-r0", @messages.first.last.fetch(:idempotency_key)
      assert_equal "orders-gift-email-#{@gift_purchase.id}-r0", @messages.last.last.fetch(:idempotency_key)
      assert_equal "sent", @gift_purchase.reload.delivery_status
      assert_not_nil @gift_purchase.delivered_at
    end

    test "retrying a partially delivered gift reuses provider keys for already accepted channels" do
      fail_email = { value: true }
      messages = @messages
      @adapter.define_singleton_method(:deliver_email) do |**attributes|
        messages << [ :email, attributes ]
        if fail_email[:value]
          Messaging::Providers::DeliveryResult.retryable(provider: "test", failure_code: "temporary")
        else
          Messaging::Providers::DeliveryResult.delivered(provider: "test")
        end
      end

      DeliverGiftPurchaseJob.perform_now(@gift_purchase.id)
      assert_equal "partial", @gift_purchase.reload.delivery_status
      first_sms_key = @messages.find { |channel, _| channel == :sms }.last.fetch(:idempotency_key)
      first_email_key = @messages.find { |channel, _| channel == :email }.last.fetch(:idempotency_key)

      fail_email[:value] = false
      DeliverGiftPurchaseJob.perform_now(@gift_purchase.id)

      sms_keys = @messages.select { |channel, _| channel == :sms }.map { |_channel, details| details.fetch(:idempotency_key) }
      email_keys = @messages.select { |channel, _| channel == :email }.map { |_channel, details| details.fetch(:idempotency_key) }
      assert_equal [ first_sms_key, first_sms_key ], sms_keys
      assert_equal [ first_email_key, first_email_key ], email_keys
      assert_equal "sent", @gift_purchase.reload.delivery_status
    end

    test "a payer-requested resend uses the next persisted delivery revision" do
      resent = Orders::GiftPurchases::Resend.call(
        gift_purchase: @gift_purchase,
        actor: @gift_purchaser,
        idempotency_key: "job-gift-resend"
      )
      assert_predicate resent, :success?, resent.error&.message

      DeliverGiftPurchaseJob.perform_now(@gift_purchase.id)

      assert_equal "orders-gift-sms-#{@gift_purchase.id}-r1", @messages.first.last.fetch(:idempotency_key)
      assert_equal "orders-gift-email-#{@gift_purchase.id}-r1", @messages.last.last.fetch(:idempotency_key)
    end

    test "the gift-ready outbox handler enqueues only the durable gift id" do
      published = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.gift_purchase.ready",
        aggregate: @gift_purchase,
        payload: { gift_purchase_id: @gift_purchase.id },
        idempotency_key: "gift-delivery-outbox-#{@gift_purchase.id}"
      )
      assert_predicate published, :success?, published.error&.message
      event = published.value
      handler = Rails.application.config.x.outbox_handlers.fetch(event.event_type)

      assert_enqueued_with(job: DeliverGiftPurchaseJob, args: [ @gift_purchase.id ]) do
        handler.call(event)
      end
      refute_includes event.payload.to_json, @gift_token
      refute_includes event.payload.to_json, @gift_phone
    end

    private

    def configure_provider
      @adapter = Object.new
      messages = @messages
      @adapter.define_singleton_method(:deliver) do |**|
        Messaging::Providers::DeliveryResult.delivered(provider: "test")
      end
      @adapter.define_singleton_method(:deliver_sms) do |**attributes|
        messages << [ :sms, attributes ]
        Messaging::Providers::DeliveryResult.delivered(provider: "test")
      end
      @adapter.define_singleton_method(:deliver_email) do |**attributes|
        messages << [ :email, attributes ]
        Messaging::Providers::DeliveryResult.delivered(provider: "test")
      end
      registry = Messaging::Providers::Registry.new
      registry.register(channel: "sms", adapter: @adapter)
      registry.register(channel: "email", adapter: @adapter)
      Rails.application.config.x.messaging_provider_registry = registry
      Rails.application.config.x.public_app_url = "https://digis.example"
    end
  end
end
