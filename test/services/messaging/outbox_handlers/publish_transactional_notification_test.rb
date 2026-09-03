# frozen_string_literal: true

require "test_helper"

module Messaging
  module OutboxHandlers
    class PublishTransactionalNotificationTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 1)
      end

      class DefinitionProbe
        attr_reader :payloads

        def initialize(recipient)
          @recipient = recipient
          @payloads = []
        end

        def recipient_for(**)
          @recipient
        end

        def project(source:, payload:)
          {
            "order_id" => source.id,
            "payment_id" => payload.fetch("payment_id"),
            "event_id" => source.event_id
          }
        end

        def dedupe_key_for(payload:, **)
          @payloads << payload
          "probed"
        end
      end

      test "projects a payment success through the recipient-owned command" do
        buyer = @owner
        order = @ticket.order_item.order
        event = Core::Outbox::Publish.call(
          topic: "orders", event_type: "orders.payment.fulfilled", aggregate: order,
          payload: { order_id: order.id, payment_id: "payment-1" },
          idempotency_key: "payment-fulfilled-#{order.id}"
        ).value
        calls = []
        publish = ->(**attributes) { calls << attributes; Core::BaseService::Result.success(:published) }

        original = Messaging::PublishNotification.method(:call)
        Messaging::PublishNotification.define_singleton_method(:call, publish)
        begin
          result = Messaging::OutboxHandlers::PublishTransactionalNotification.call(event:)

          assert_predicate result, :success?, result.error&.message
        ensure
          Messaging::PublishNotification.define_singleton_method(:call, original)
        end

        assert_equal 1, calls.length
        assert_equal "payment_succeeded", calls.first.fetch(:type)
        assert_equal buyer, calls.first.fetch(:recipient)
        assert_equal order, calls.first.fetch(:source)
        assert_equal "payment-succeeded:payment-1:v1", calls.first.fetch(:dedupe_key)
      end

      test "reuses one projection for persistence and deduplication" do
        buyer = @owner
        order = @ticket.order_item.order
        event = Core::Outbox::Publish.call(
          topic: "orders", event_type: "orders.payment.fulfilled", aggregate: order,
          payload: { order_id: order.id, payment_id: "payment-2" },
          idempotency_key: "payment-fulfilled-#{order.id}-2"
        ).value
        definition = DefinitionProbe.new(buyer)
        calls = []

        Messaging::NotificationTypes.expects(:fetch).with("payment_succeeded").returns(definition)
        Messaging::PublishNotification.expects(:call).with { |attributes| calls << attributes }.returns(
          Core::BaseService::Result.success(:published)
        )

        result = Messaging::OutboxHandlers::PublishTransactionalNotification.call(event:)

        assert_predicate result, :success?, result.error&.message
        assert_same calls.first.fetch(:data), definition.payloads.first
      end

      test "hands schedule changes to bounded fan-out without inline recipients" do
        event = Core::Outbox::Publish.call(
          topic: "events", event_type: "events.schedule_changed", aggregate: @event,
          payload: { event_id: @event.id, version: 2, event_date_ids: [] },
          idempotency_key: "schedule-change-#{@event.id}-2"
        ).value
        enqueued = []

        original = Messaging::FanoutNotificationJob.method(:perform_later)
        Messaging::FanoutNotificationJob.define_singleton_method(:perform_later) { |*args| enqueued << args }
        begin
          result = Messaging::OutboxHandlers::PublishTransactionalNotification.call(event:)

          assert_predicate result, :success?, result.error&.message
        ensure
          Messaging::FanoutNotificationJob.define_singleton_method(:perform_later, original)
        end

        assert_equal [ [ event.id ] ], enqueued
      end
    end
  end
end
