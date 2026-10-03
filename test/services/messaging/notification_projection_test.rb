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

    test "incoming transfer projection rejects bearer credentials and contact data" do
      %w[token token_digest phone email].each do |key|
        assert_raises(Messaging::NotificationProjection::UnsafeData, key) do
          Messaging::NotificationProjection.call(
            "transfer_incoming",
            {
              transfer_id: "transfer-1", ticket_id: "ticket-1", event_id: "event-1",
              event_title: "Concert", ticket_label: "General", expires_at: "2026-10-10T00:00:00Z",
              key => "sensitive"
            }
          )
        end
      end
    end
  end
end
