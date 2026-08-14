# frozen_string_literal: true

require "test_helper"

module Events
  module Cancellation
    class PrepareBatchTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper
      include Events::CancellationTestHelpers
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:core_admin)
      end

      test "snapshots accepted payments once and enqueues bounded processing" do
        _order, _item, accepted_payment = create_cancellation_order
        _other_order, _other_item, unaccepted_payment = create_cancellation_order(accepted: false)
        cancellation = initiate_cancellation

        assert_enqueued_with(job: Events::ProcessCancellationBatchJob, args: [ cancellation.id ]) do
          result = PrepareBatch.call(cancellation:)
          assert_predicate result, :success?, result.error&.message
        end

        assert_equal [ accepted_payment.id ], Events::EventCancellationPayment.where(
          event_cancellation: cancellation
        ).pluck(:payment_id)
        assert_not Events::EventCancellationPayment.exists?(payment_id: unaccepted_payment.id)
        assert_equal 1, cancellation.reload.total_payments_count
        assert_equal "processing", cancellation.status
        assert_not_nil cancellation.refunds_started_at
      end

      test "replaying the cancellation outbox event does not duplicate snapshots" do
        _order, _item, = create_cancellation_order
        cancellation = initiate_cancellation
        outbox_event = Core::OutboxEvent.find_by!(
          event_type: "events.cancellation_initiated", aggregate_id: @event.id
        )
        handler = Rails.application.config.x.outbox_handlers.fetch(outbox_event.event_type)

        handler.call(outbox_event)
        handler.call(outbox_event)

        assert_equal 1, Events::EventCancellationPayment.where(
          event_cancellation: cancellation
        ).count
      end

      test "cancels future event dates while retaining their stable identities" do
        first_date = @event.event_dates.create!(
          starts_at: 2.days.from_now,
          ends_at: 2.days.from_now + 4.hours,
          status: "scheduled"
        )
        second_date = @event.event_dates.create!(
          starts_at: 3.days.from_now,
          ends_at: 3.days.from_now + 4.hours,
          status: "scheduled"
        )
        cancellation = initiate_cancellation
        PrepareBatch.call(cancellation:)

        assert_equal %w[cancelled cancelled], @event.event_dates.where(id: [ first_date.id, second_date.id ]).order(:id).pluck(:status)
        assert_equal [ first_date.id, second_date.id ], @event.event_dates.where(id: [ first_date.id, second_date.id ]).order(:id).pluck(:id)
      end

      test "stops streams and releases active registrations during preparation" do
        stream_date = @event.event_dates.create!(
          starts_at: 2.days.from_now,
          ends_at: 2.days.from_now + 4.hours,
          status: "scheduled"
        )
        stream = Events::EventStream.create!(
          event_date: stream_date,
          provider: "test",
          access_protection: "public",
          status: "live",
          live_from: Time.current,
          live_until: 2.days.from_now,
          provider_playback_id: "playback-#{SecureRandom.hex(4)}"
        )
        @owner = core_users(:attendee)
        @manager = core_users(:super_admin)
        @product = create_package_product(admissions_per_unit: 1, delegation_enabled: false, transferable: false)
        registration = create_confirmed_registration
        cancellation = initiate_cancellation

        result = PrepareBatch.call(cancellation:)

        assert_predicate result, :success?, result.error&.message
        assert_equal "ended", stream.reload.status
        assert_equal "cancelled", registration.reload.status
      end
    end
  end
end
