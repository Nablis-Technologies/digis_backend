# frozen_string_literal: true

require "test_helper"

module Messaging
  class NotificationTypesTest < ActiveSupport::TestCase
    test "credential notifications always include in-app" do
      definition = Messaging::NotificationTypes.fetch("ticket_issued")

      assert_equal "credential", definition.category
      assert_predicate definition, :mandatory?
      assert_includes definition.channels, "in_app"
    end

    test "unknown types fail through the typed error" do
      assert_raises(Messaging::NotificationTypes::UnknownType) do
        Messaging::NotificationTypes.fetch("unknown_type")
      end
    end

    test "type definitions expose version-aware dedupe identities" do
      definition = Messaging::NotificationTypes.fetch("credential_replaced")
      ticket = Struct.new(:id, :credential_version).new("ticket-1", 2)
      user = Struct.new(:id).new("user-1")

      key = definition.dedupe_key_for(
        source: ticket, recipient: user, payload: { "version" => 2 }
      )

      assert_includes key, "ticket-1"
      assert_includes key, "v2"
    end

    test "definitions own their source-aware projections" do
      buyer = core_users(:attendee)
      source = Struct.new(:id, :buyer_user, :event_id, keyword_init: true)
        .new(id: "order-1", buyer_user: buyer, event_id: "event-1")
      definition = Messaging::NotificationTypes.fetch("payment_succeeded")

      assert_equal(
        { "order_id" => "order-1", "payment_id" => "payment-1", "event_id" => "event-1" },
        definition.project(
          source:, payload: { "order_id" => "ignored", "payment_id" => "payment-1" }
        )
      )
    end

    test "incoming transfer notifications are recipient-owned and in-app only" do
      event = Struct.new(:title).new("Chapa Test Event")
      product = Struct.new(:name).new("General Admission")
      ticket = Struct.new(:event_id, :event, :event_product)
        .new("event-1", event, product)
      recipient = Object.new
      recipient.define_singleton_method(:id) { "recipient-1" }
      expires_at = Time.utc(2026, 10, 10)
      transfer = Struct.new(:id, :to_user, :ticket_id, :ticket, :expires_at)
        .new("transfer-1", recipient, "ticket-1", ticket, expires_at)
      definition = Messaging::NotificationTypes.fetch("transfer_incoming")

      assert_equal "transactional", definition.category
      assert_equal [ "in_app" ], definition.channels
      assert_equal recipient, definition.recipient_for(source: transfer)
      assert_equal "transfer-incoming:transfer-1:v1",
        definition.dedupe_key_for(source: transfer, recipient:)
      assert_equal(
        {
          "transfer_id" => "transfer-1",
          "ticket_id" => "ticket-1",
          "event_id" => "event-1",
          "event_title" => "Chapa Test Event",
          "ticket_label" => "General Admission",
          "expires_at" => expires_at.iso8601
        },
        definition.project(source: transfer, payload: {})
      )
    end

    test "ticket projections derive the label used by seed and outbox paths" do
      event = Struct.new(:title).new("Chapa Test Event")
      product = Struct.new(:name).new("General Admission")
      source = Struct.new(:id, :event_id, :event_product_id, :credential_version, :event, :event_product)
        .new("ticket-1", "event-1", "product-1", 1, event, product)
      definition = Messaging::NotificationTypes.fetch("ticket_issued")

      assert_equal(
        {
          "ticket_id" => "ticket-1",
          "event_id" => "event-1",
          "product_id" => "product-1",
          "version" => 1,
          "event_title" => "Chapa Test Event",
          "ticket_label" => "General Admission"
        },
        definition.project(source:, payload: { "ticket_id" => "ignored", "version" => 1 })
      )
    end
  end
end
