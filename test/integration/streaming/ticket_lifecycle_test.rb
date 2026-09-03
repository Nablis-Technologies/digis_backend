# frozen_string_literal: true

require "test_helper"

module Streaming
  class TicketLifecycleTest < ActionDispatch::IntegrationTest
    include StreamingTestHelpers

    setup do
      create_messaging_policy
      @now = Time.current
      build_streaming_ticket(now: @now)
      @session_result = Streaming::Sessions::Create.call(
        ticket: @stream_ticket,
        event_stream: @event_stream,
        user: @stream_buyer,
        device_id: "ios:lifecycle",
        now: @now,
        idempotency_key: "stream-lifecycle:#{@stream_ticket.id}"
      )
      assert_predicate @session_result, :success?, @session_result.error&.message
      @session = @session_result.value.session
    end

    test "registered lifecycle handlers enqueue bounded ticket revocation" do
      handlers = Rails.application.config.x.outbox_handlers

      assert_includes handlers, "ticketing.credential_generation_replaced"
      assert_includes handlers, "ticketing.ticket_suspension.changed"
      assert_includes handlers, "ticketing.package_refunded"
      assert_includes handlers, "marketplace.resale_listing.reserved"
      assert_includes handlers, "events.cancellation_initiated"

      event = Core::Outbox::Publish.call(
        topic: "ticketing",
        event_type: "ticketing.credential_generation_replaced",
        aggregate: @stream_ticket,
        payload: { ticket_id: @stream_ticket.id, version: 2 },
        idempotency_key: "stream-lifecycle-event:#{@stream_ticket.id}"
      ).value

      assert_enqueued_with(
        job: Streaming::RevokeTicketSessionsJob,
        args: [ { ticket_id: @stream_ticket.id, event_id: nil, idempotency_key: event.idempotency_key } ]
      ) do
        handlers.fetch(event.event_type).call(event)
      end
    end

    test "ticket-scoped lifecycle handlers accept durable ticket identifiers" do
      %w[
        ticketing.ticket_suspension.changed
        ticketing.package_refunded
        marketplace.resale_listing.reserved
      ].each do |event_type|
        event = Core::OutboxEvent.new(
          event_type:,
          payload: { ticket_id: @stream_ticket.id },
          idempotency_key: "stream-lifecycle-handler:#{event_type}"
        )

        assert_enqueued_with(
          job: Streaming::RevokeTicketSessionsJob,
          args: [ { ticket_id: @stream_ticket.id, event_id: nil, idempotency_key: event.idempotency_key } ]
        ) do
          result = Rails.application.config.x.outbox_handlers.fetch(event_type).call(event)
          assert_predicate result, :success?, result.error&.message
        end
      end
    end

    test "event-scoped revocation closes sessions without requiring ticket payload" do
      perform_revoke(
        ticket_id: nil,
        event_id: @stream_event.id,
        idempotency_key: "stream-event-lifecycle-job:#{@stream_event.id}"
      )

      assert_equal "revoked", @session.reload.status
    end

    test "lifecycle handler fails closed when an event has no durable scope" do
      event = Core::OutboxEvent.new(
        event_type: "ticketing.package_refunded",
        payload: {},
        idempotency_key: "stream-invalid-lifecycle-event"
      )

      result = Streaming::OutboxHandlers::RevokeTicketSessions.call(event:)

      assert_predicate result, :failure?
      assert_equal "invalid_lifecycle_event", result.error.code
    end

    test "revoke job closes sessions and is idempotent" do
      perform_revoke(
        ticket_id: @stream_ticket.id,
        event_id: nil,
        idempotency_key: "stream-lifecycle-job:#{@stream_ticket.id}"
      )

      assert_equal "revoked", @session.reload.status
      assert_not_nil @session.revoked_at

      assert_nothing_raised do
        perform_revoke(
          ticket_id: @stream_ticket.id,
          event_id: nil,
          idempotency_key: "stream-lifecycle-job:#{@stream_ticket.id}"
        )
      end
    end

    test "suspended ticket authorization fails before lifecycle delivery" do
      @stream_ticket.update!(status: "suspended")

      result = Streaming::Sessions::Refresh.call(
        session: @session,
        session_token: @session_result.value.session_token,
        user: @stream_buyer,
        now: @now,
        idempotency_key: "stream-lifecycle-refresh:#{@session.id}"
      )

      assert_predicate result, :failure?
      assert_equal "ticket_not_active", result.error.code
    end

    private

    def perform_revoke(**options)
      Prosopite.pause { Streaming::RevokeTicketSessionsJob.perform_now(**options) }
    end
  end
end
