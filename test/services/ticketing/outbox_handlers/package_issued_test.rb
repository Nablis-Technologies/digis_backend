# frozen_string_literal: true

require "test_helper"

module Ticketing
  module OutboxHandlers
    class PackageIssuedTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        create_messaging_policy
        setup_package_workflow(admissions_per_unit: 1)
      end

      test "replaying a package-issued chain gives the sender one durable identity" do
        event = core_outbox_events(:pending)
        event.update!(
          topic: "ticketing",
          event_type: "ticketing.package_issued",
          aggregate_type: "Ticketing::Ticket",
          aggregate_id: @ticket.id,
          payload: { ticket_id: @ticket.id, version: 1 },
          idempotency_key: "ticketing-package-issued-replay"
        )
        deliveries = {}
        previous_sender = Rails.application.config.x.credential_delivery_sender
        Rails.application.config.x.credential_delivery_sender = lambda do |**details|
          deliveries[details.fetch(:idempotency_key)] ||= details
        end

        begin
          subject = -> { Rails.application.config.x.outbox_handlers.fetch(event.event_type).call(event) }
          assert_idempotent(subject, counter: -> { deliveries.size })
        ensure
          Rails.application.config.x.credential_delivery_sender = previous_sender
        end

        assert_equal 1, deliveries.size
        assert_equal event.idempotency_key, deliveries.keys.first
      end
    end
  end
end
