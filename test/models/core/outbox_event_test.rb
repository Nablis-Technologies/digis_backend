# frozen_string_literal: true

require "test_helper"

module Core
  class OutboxEventTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ActiveJob::TestHelper

    setup do
      clear_enqueued_jobs
      @original_immediate_dispatch = Rails.application.config.x.outbox_immediate_dispatch
      Rails.application.config.x.outbox_immediate_dispatch = true
      @created_ids = []
    end

    teardown do
      Core::OutboxEvent.where(id: @created_ids).delete_all
      Rails.application.config.x.outbox_immediate_dispatch = @original_immediate_dispatch
    end

    test "enqueues immediate dispatch for a due unpublished event" do
      event = create_event

      assert_enqueued_with(job: Core::DispatchOutboxEventJob, args: [ event.id ])
    end

    test "does not dispatch a future-dated event early" do
      assert_no_enqueued_jobs do
        create_event(available_at: 1.minute.from_now)
      end
    end

    test "does not dispatch a published event" do
      assert_no_enqueued_jobs do
        create_event(published_at: Time.current)
      end
    end

    test "does not dispatch when immediate dispatch is disabled" do
      Rails.application.config.x.outbox_immediate_dispatch = false

      assert_no_enqueued_jobs do
        create_event
      end
    end

    test "does not dispatch a rolled-back event" do
      assert_no_enqueued_jobs do
        ActiveRecord::Base.transaction do
          create_event
          raise ActiveRecord::Rollback
        end
      end
    end

    test "keeps the committed event when queue enqueue fails" do
      Core::DispatchOutboxEventJob.expects(:perform_later).raises(RuntimeError, "queue unavailable")

      event = create_event

      assert Core::OutboxEvent.exists?(event.id)
    end

    private

    def create_event(available_at: Time.current, published_at: nil)
      event = Core::OutboxEvent.create!(
        topic: "test",
        event_type: "test.outbox",
        aggregate_type: "Core::OutboxEvent",
        aggregate_id: SecureRandom.uuid,
        payload: {},
        idempotency_key: "outbox-event-test-#{SecureRandom.uuid}",
        occurred_at: Time.current - 1.second,
        available_at:,
        published_at:
      )
      @created_ids << event.id
      event
    end
  end
end
