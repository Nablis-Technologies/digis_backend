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
  end
end
