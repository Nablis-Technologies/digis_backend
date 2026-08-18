# frozen_string_literal: true

require "test_helper"

module Events
  class EventCancellationPaymentTest < ActiveSupport::TestCase
    include Events::CancellationTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @actor = core_users(:core_admin)
      @other_event = Events::Event.create!(
        organization: @event.organization,
        created_by: @actor,
        title: "Other cancellation event #{SecureRandom.hex(4)}",
        slug: "other-cancellation-event-#{SecureRandom.hex(4)}",
        status: "draft",
        visibility: "private",
        timezone: "Africa/Addis_Ababa",
        currency: "ETB",
        version: 1
      )
      @cancellation = Events::EventCancellation.create!(
        event: @event,
        initiated_by: @actor,
        status: "pending",
        attendee_reason: "The event will not proceed.",
        initiated_at: Time.current,
        idempotency_key: "cancellation-payment-#{SecureRandom.hex(5)}"
      )
    end

    test "requires an accepted payment from the cancellation event" do
      _order, _item, payment = create_cancellation_order
      snapshot = Events::EventCancellationPayment.new(
        event_cancellation: @cancellation,
        payment:
      )

      assert snapshot.valid?, snapshot.errors.full_messages.inspect
      assert_equal "pending", snapshot.status
    end

    test "rejects a payment from another event at the database boundary" do
      _order, _item, payment = create_cancellation_order
      other_cancellation = Events::EventCancellation.create!(
        event: @other_event,
        initiated_by: @actor,
        status: "pending",
        attendee_reason: "The event will not proceed.",
        initiated_at: Time.current,
        idempotency_key: "other-cancellation-payment-#{SecureRandom.hex(5)}"
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Events::EventCancellationPayment.insert_all!([ {
          id: SecureRandom.uuid,
          event_cancellation_id: other_cancellation.id,
          payment_id: payment.id,
          status: "pending",
          attempts: 0,
          lock_version: 0,
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end

    test "rejects an unaccepted succeeded payment at the database boundary" do
      _order, _item, payment = create_cancellation_order(accepted: false)

      assert_raises(ActiveRecord::StatementInvalid) do
        Events::EventCancellationPayment.insert_all!([ {
          id: SecureRandom.uuid,
          event_cancellation_id: @cancellation.id,
          payment_id: payment.id,
          status: "pending",
          attempts: 0,
          lock_version: 0,
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end

    test "allows one snapshot per cancellation and payment" do
      _order, _item, payment = create_cancellation_order
      first = Events::EventCancellationPayment.create!(
        event_cancellation: @cancellation,
        payment:
      )

      assert_raises(ActiveRecord::RecordNotUnique) do
        Events::EventCancellationPayment.create!(
          event_cancellation: @cancellation,
          payment:
        )
      end
      assert_equal first.id, Events::EventCancellationPayment.find_by!(
        event_cancellation: @cancellation,
        payment:
      ).id
    end
  end
end
