# frozen_string_literal: true

require "test_helper"

class Core::Outbox::PublishTest < ActiveSupport::TestCase
  test "publishes once for one aggregate idempotency key" do
    aggregate = organizations_organizations(:one)

    assert_difference("Core::OutboxEvent.count", 1) do
      2.times do
        Core::Outbox::Publish.call(
          topic: "events",
          event_type: "events.published",
          aggregate:,
          payload: { event_id: "event-id" },
          idempotency_key: "publish:event-id:1"
        )
      end
    end
  end

  test "rejects sensitive payload keys" do
    aggregate = organizations_organizations(:one)

    assert_raises(Core::Outbox::Publish::SensitivePayload) do
      Core::Outbox::Publish.call(
        topic: "ticketing",
        event_type: "ticketing.credential.issued",
        aggregate:,
        payload: { qr_token: "secret" },
        idempotency_key: "credential:1"
      )
    end
  end

  test "rejects reuse of one key for different content" do
    aggregate = organizations_organizations(:one)
    Core::Outbox::Publish.call(
      topic: "events", event_type: "events.published", aggregate:,
      payload: { event_id: "first" }, idempotency_key: "publish:collision"
    )

    assert_raises(Core::Outbox::Publish::IdempotencyConflict) do
      Core::Outbox::Publish.call(
        topic: "events", event_type: "events.published", aggregate:,
        payload: { event_id: "different" }, idempotency_key: "publish:collision"
      )
    end
  end
end
