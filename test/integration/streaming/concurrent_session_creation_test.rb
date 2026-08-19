# frozen_string_literal: true

require "test_helper"

module Streaming
  class ConcurrentSessionCreationTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include StreamingTestHelpers

    setup do
      @now = Time.current
      build_streaming_ticket(now: @now, max_concurrent_devices: 1)
    end

    teardown do
      Ticketing::ApplicationRecord.transaction do
        Ticketing::StreamSession.where(ticket_id: @stream_ticket.id).delete_all
        @stream_ticket.update_columns(current_credential_generation_id: nil)
        Ticketing::Credential.where(ticket_id: @stream_ticket.id).delete_all
        Ticketing::CredentialGeneration.where(ticket_id: @stream_ticket.id).delete_all
        Ticketing::AdmissionSlot.where(ticket_id: @stream_ticket.id).delete_all
      end
      Ticketing::Ticket.where(id: @stream_ticket.id).delete_all
      Ticketing::Registration.where(id: @stream_registration.id).delete_all
      Catalog::ProductAccess.where(event_product_id: @stream_product.id).delete_all
      Ticketing::TicketType.where(event_product_id: @stream_product.id).delete_all
      Catalog::EventProduct.where(id: @stream_product.id).delete_all
      Events::EventStream.where(id: @event_stream.id).delete_all
      Events::EventDate.where(id: @stream_date.id).delete_all
    end

    test "concurrent distinct devices cannot exceed the stream device limit" do
      ready = Queue.new
      start = Queue.new
      threads = 2.times.map do |index|
        Thread.new do
          ready << true
          start.pop
          Ticketing::ApplicationRecord.connection_pool.with_connection do
            Streaming::Sessions::Create.call(
              ticket: Ticketing::Ticket.find(@stream_ticket.id),
              event_stream: Events::EventStream.find(@event_stream.id),
              user: Core::User.find(@stream_buyer.id),
              device_id: "ios:concurrent-#{index}",
              now: @now,
              idempotency_key: "stream-concurrent:#{@stream_ticket.id}:#{index}"
            )
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)

      assert_equal 1, results.count(&:success?)
      assert_equal 1, results.count(&:failure?)
      assert_equal "stream_device_limit_reached", results.find(&:failure?).error.code
      assert_equal 1, Ticketing::StreamSession.where(ticket_id: @stream_ticket.id, status: "active").count
    ensure
      threads&.each(&:join)
    end
  end
end
