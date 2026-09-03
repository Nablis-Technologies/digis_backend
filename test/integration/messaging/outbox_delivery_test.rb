# frozen_string_literal: true

require "test_helper"

module Messaging
  class OutboxDeliveryTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      create_messaging_policy
      setup_package_workflow(admissions_per_unit: 1)
    end

    test "projects payment fulfillment once when the composed outbox chain replays" do
      item = @ticket.order_item
      event = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.payment.fulfilled",
        aggregate: item.order,
        payload: { order_id: item.order_id, order_item_ids: [ item.id ] },
        idempotency_key: "messaging-payment-fulfillment-#{item.order_id}"
      ).value
      handler = Rails.application.config.x.outbox_handlers.fetch(event.event_type)

      first = handler.call(event)
      second = handler.call(event)

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :success?, second.error&.message
      notification = Messaging::Notification.find_by!(
        notification_type: "payment_succeeded", source: item.order, user: @owner
      )
      assert_equal 1, Messaging::Notification.where(id: notification.id).count
      assert_equal 1, notification.deliveries.where(channel: "in_app").count
    end

    test "projects an expired waitlist offer after its durable producer event" do
      ticket_type = create_waitlist_ticket_type
      registration = create_waitlisted_registration(ticket_type:)
      assert_predicate Ticketing::Waitlist::OfferNext.call(
        ticket_type:, idempotency_key: "messaging-offer-#{registration.id}"
      ), :success?
      registration.reload.update_columns(offered_at: 2.minutes.ago, offer_expires_at: 1.second.ago)
      assert_predicate Ticketing::Waitlist::ExpireOffer.call(
        registration:, idempotency_key: "messaging-expire-#{registration.id}"
      ), :success?
      event = Core::OutboxEvent.find_by!(
        aggregate_id: registration.id,
        event_type: "ticketing.registration.waitlist_offer_expired"
      )

      dispatch = Core::Outbox::Dispatch.call(event_id: event.id)

      assert_predicate dispatch, :success?, dispatch.error&.message
      assert Messaging::Notification.exists?(
        user_id: registration.user_id,
        notification_type: "waitlist_offer_expired",
        source_id: registration.id
      )
    end

    private

    def create_waitlist_ticket_type
      product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: @manager,
        product_attributes: { name: "Messaging waitlist #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1, waitlist_enabled: true
        },
        price_attributes: { currency: "ETB", amount_minor: 1, active_from: Time.current },
        inventory_configuration: { mode: "event_wide", capacity: 1 }
      ).value
      assert_predicate Catalog::Products::Activate.call(product:, actor: @manager), :success?
      product.reload.ticket_type
    end

    def create_waitlisted_registration(ticket_type:)
      Ticketing::Registration.create!(
        event: @event,
        ticket_type:,
        user: @owner,
        created_by: @owner,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "waitlisted",
        waitlisted_at: Time.current,
        submitted_at: Time.current
      )
    end
  end
end
