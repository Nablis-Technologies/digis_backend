# frozen_string_literal: true

require "test_helper"

module Commercial
  class HandleEventPublishedJobTest < ActiveJob::TestCase
    include Commercial::EntitlementTestHelpers

    setup do
      @organization = organizations_organizations(:two)
      @program, @assignment = create_first_event_program(organization: @organization)
      @event = create_published_event(organization: @organization, published_at: 1.hour.ago)
    end

    teardown do
      delete_first_event_program!(@program, @assignment)
      Events::Event.where(id: @event.id).delete_all
    end

    test "reconciles the entitlement from an event id" do
      Commercial::HandleEventPublishedJob.perform_now(@event.id)

      entitlement = Commercial::ProgramEntitlement.find_by!(program: @program, organization: @organization)
      assert_equal "reserved", entitlement.status
      assert_equal @event.id, entitlement.reserved_event_id
    end

    test "replaying the handler is safe" do
      replay = -> { 2.times { Commercial::HandleEventPublishedJob.perform_now(@event.id) } }
      defined?(Prosopite) ? Prosopite.pause(&replay) : replay.call

      assert_equal 1, Commercial::ProgramEntitlement.where(program: @program, organization: @organization).count
      assert_equal 1, Core::AuditLog.where(
        action: "commercial.program_entitlement.reserved",
        auditable_type: "Commercial::ProgramEntitlement"
      ).count
    end

    test "ignores a missing event" do
      assert_nothing_raised do
        Commercial::HandleEventPublishedJob.perform_now("00000000-0000-0000-0000-000000000000")
      end
    end

    test "event.published dispatch registration enqueues this job" do
      outbox_event = Core::OutboxEvent.create!(
        topic: "events",
        event_type: "event.published",
        aggregate_type: "Events::Event",
        aggregate_id: @event.id,
        payload: { event_id: @event.id },
        idempotency_key: "event-published-test-#{@event.id}",
        occurred_at: @event.published_at,
        available_at: @event.published_at
      )
      handler = Rails.application.config.x.outbox_handlers.fetch("event.published")

      assert_enqueued_with(job: Commercial::HandleEventPublishedJob, args: [ @event.id ]) do
        handler.call(outbox_event)
      end
    end
  end
end
