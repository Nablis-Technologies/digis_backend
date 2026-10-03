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

      test "replays a seed-shaped ticket notification through package-issued outbox" do
        create_messaging_policy
        ticket = Ticketing::Ticket.includes(:owner_user, :event, :event_product).find(@ticket.id)
        event = Core::OutboxEvent.find_by!(aggregate_id: ticket.id, event_type: "ticketing.package_issued")
        manual = Messaging::PublishNotification.call(
          type: "ticket_issued", recipient: ticket.owner_user, source: ticket,
          data: {
            ticket_id: ticket.id, event_id: ticket.event_id, product_id: ticket.event_product_id,
            version: ticket.credential_version, event_title: ticket.event.title,
            ticket_label: ticket.event_product.name
          },
          dedupe_key: "ticket-issued:#{ticket.id}:v#{ticket.credential_version}"
        )

        assert_predicate manual, :success?, manual.error&.message
        dispatch = Core::Outbox::Dispatch.call(event_id: event.id)

        assert_predicate dispatch, :success?, dispatch.error&.message
        assert_equal 1, Messaging::Notification.where(source: ticket, notification_type: "ticket_issued").count
      end

      test "projects initiated ticket transfers to one recipient-owned in-app notification" do
        create_messaging_policy
        initiated = Ticketing::Transfers::Initiate.call(
          ticket: @ticket,
          actor: @owner,
          phone: @recipient.phone,
          idempotency_key: "notification-transfer-initiate"
        )
        assert_predicate initiated, :success?, initiated.error&.message

        event = Core::OutboxEvent.find_by!(
          aggregate: initiated.value.transfer,
          event_type: "ticketing.ticket_transfer.initiated"
        )
        first = Messaging::OutboxHandlers::PublishTransactionalNotification.call(event:)
        replay = Messaging::OutboxHandlers::PublishTransactionalNotification.call(event:)

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        notification = Messaging::Notification.find_by!(
          source: initiated.value.transfer,
          notification_type: "transfer_incoming"
        )
        assert_equal @recipient.id, notification.user_id
        assert_equal [ "in_app" ], Messaging::NotificationDelivery
          .where(notification_id: notification.id).order(:channel).pluck(:channel)
        assert_equal(
          %w[event_id event_title expires_at ticket_id ticket_label transfer_id],
          notification.data.keys.sort
        )
        refute notification.data.key?("token")
        refute notification.data.key?("token_digest")
        refute notification.data.key?("phone")
        refute notification.data.key?("email")
        assert_equal 1, Messaging::Notification.where(
          source: initiated.value.transfer,
          notification_type: "transfer_incoming"
        ).count
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

      test "acknowledges billing refunds without projecting an event notification" do
        purchase = Orders::BillingPurchase.create!(
          organization: @event.organization, requested_by: @owner,
          kind: "messaging_credit_top_up", source_type: "Messaging::CreditTopUp", source_id: SecureRandom.uuid,
          currency: "ETB", amount_minor: 100, price_digest: "a" * 64, status: "paid",
          idempotency_key_digest: SecureRandom.hex(32), expires_at: 30.minutes.from_now
        )
        payment = Orders::Payment.create!(
          billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
          status: "succeeded", amount_minor: 100, currency: "ETB", accepted_at: Time.current,
          succeeded_at: Time.current, billing_purchase_price_digest: purchase.price_digest,
          buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "notification-billing-refund",
          settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
        )
        refund = Orders::Refund.create!(
          payment:, type: "payment_reversal", idempotency_key: "notification-billing-refund-row",
          amount_minor: 100, currency: "ETB", status: "succeeded", reason_code: "duplicate_payment"
        )
        event = Core::Outbox::Publish.call(
          topic: "orders", event_type: "orders.refund.succeeded", aggregate: refund,
          payload: { refund_id: refund.id, payment_id: payment.id, status: "succeeded" },
          idempotency_key: "notification-billing-refund-event"
        ).value

        result = PublishTransactionalNotification.call(event:)

        assert_predicate result, :success?, result.error&.message
        assert_empty Messaging::Notification.where(notification_type: "refund_succeeded")
      end
    end
  end
end
