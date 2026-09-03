# frozen_string_literal: true

require "test_helper"

module Messaging
  class NotificationProjectionTest < ActiveSupport::TestCase
    test "projection rejects credentials and raw contacts" do
      assert_raises(Messaging::NotificationProjection::UnsafeData) do
        Messaging::NotificationProjection.call("ticket_issued", { token: "secret" })
      end
    end

    test "projection rejects keys that are not registered for the type" do
      assert_raises(Messaging::NotificationProjection::UnsafeData) do
        Messaging::NotificationProjection.call(
          "ticket_issued", { event_title: "Concert", internal_note: "secret" }
        )
      end
    end

    test "projection rejects forbidden keys nested inside allowed values" do
      assert_raises(Messaging::NotificationProjection::UnsafeData) do
        Messaging::NotificationProjection.call(
          "ticket_issued", { event_title: { token: "secret" } }
        )
      end
    end

    test "projection returns a canonical JSON-safe hash" do
      projected = Messaging::NotificationProjection.call(
        "ticket_issued", { ticket_label: "General", event_title: "Concert" }
      )

      assert_equal({ "event_title" => "Concert", "ticket_label" => "General" }, projected)
      assert_predicate projected, :frozen?
    end
  end
end
