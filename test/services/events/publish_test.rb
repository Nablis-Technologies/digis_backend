# frozen_string_literal: true

require "test_helper"

class Events::PublishTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "publishes a ready listing-only event once" do
    event = events_events(:ready_listing)
    actor = core_users(:super_admin)
    organization = event.organization
    make_verified(organization)
    make_publishable(event)

    assert_difference -> { Core::OutboxEvent.where(event_type: "event.published").count }, 1 do
      result = Events::Publish.call(event:, actor:, idempotency_key: SecureRandom.uuid)
      assert result.success?, result.error.inspect
    end

    assert_equal "published", event.reload.status
    assert event.published_at
    assert_equal 1, event.audit_logs.for_action("event.published").count
  end

  def make_verified(organization)
    Core::Review.create!(
      reviewable: organization,
      context: "verification",
      status: "approved"
    )
  end

  test "idempotent repeated publish does not duplicate outbox or audit" do
    event = events_events(:ready_listing)
    actor = core_users(:super_admin)
    make_verified(event.organization)
    make_publishable(event)
    key = SecureRandom.uuid

    Events::Publish.call(event:, actor:, idempotency_key: key)
    outbox_count = Core::OutboxEvent.where(event_type: "event.published").count
    audit_count = event.audit_logs.for_action("event.published").count

    Events::Publish.call(event:, actor:, idempotency_key: key)

    assert_equal outbox_count, Core::OutboxEvent.where(event_type: "event.published").count
    assert_equal audit_count, event.audit_logs.for_action("event.published").count
  end

  test "event.published dispatch fans out discovery and commercial reconciliation" do
    event = events_events(:ready_listing)
    actor = core_users(:super_admin)
    make_verified(event.organization)
    make_publishable(event)

    result = Events::Publish.call(event:, actor:, idempotency_key: SecureRandom.uuid)
    assert result.success?, result.error.inspect

    outbox_event = Core::OutboxEvent.find_by!(
      event_type: "event.published", aggregate_type: "Events::Event", aggregate_id: event.id
    )
    handler = Rails.application.config.x.outbox_handlers.fetch("event.published")

    assert_enqueued_with(job: Events::RefreshDiscoveryJob, args: [ event.id ]) do
      assert_enqueued_with(job: Commercial::HandleEventPublishedJob, args: [ event.id ]) do
        handler.call(outbox_event)
      end
    end
  end

  test "cannot publish an event whose organization is not verified" do
    event = events_events(:ready_listing)
    actor = core_users(:super_admin)

    result = Events::Publish.call(event:, actor:, idempotency_key: SecureRandom.uuid)
    assert result.failure?
    assert_equal "organization_not_verified", result.error.code
    assert_equal "draft", event.reload.status
  end

  test "cannot publish without required category and date" do
    event = events_events(:ready_listing)
    actor = core_users(:super_admin)
    make_verified(event.organization)
    event.event_categories.destroy_all

    result = Events::Publish.call(event:, actor:, idempotency_key: SecureRandom.uuid)
    assert result.failure?
    assert_equal "not_ready", result.error.code
  end
end
