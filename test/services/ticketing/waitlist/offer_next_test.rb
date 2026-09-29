# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Waitlist
    class OfferNextTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @attendee = core_users(:attendee)
        @manager = core_users(:super_admin)
      end

      test "offers the oldest complete party that fits instead of splitting a party" do
        ticket_type = create_ticket_type(capacity: 3, amount_minor: 1)
        inventory = ticket_type.event_product.inventories.find_by!(event_date_id: nil)
        inventory.update!(sold_count: 1)
        too_large = create_waitlisted_registration(ticket_type:, package_quantity: 3, waitlisted_at: 5.minutes.ago)
        fitting = create_waitlisted_registration(ticket_type:, package_quantity: 2, waitlisted_at: 1.minute.ago)

        result = OfferNext.call(ticket_type:, idempotency_key: "offer-next")

        assert_predicate result, :success?
        assert_equal fitting, result.value
        assert_equal "waitlisted", too_large.reload.status
        assert_equal "offered", fitting.reload.status
        assert_equal 2, Catalog::InventoryReservation.where(registration_id: fitting.id).sum(:quantity)
        assert_equal 0, Catalog::InventoryReservation.where(registration_id: too_large.id).count
      end

      test "expires an offer, releases its hold, and requeues it at the back" do
        ticket_type = create_ticket_type(capacity: 1, amount_minor: 1)
        registration = create_waitlisted_registration(ticket_type:)
        original_waitlisted_at = registration.waitlisted_at
        assert_predicate OfferNext.call(ticket_type:, idempotency_key: "offer-expiry"), :success?
        registration.reload
        registration.update_columns(offered_at: 2.minutes.ago, offer_expires_at: 1.second.ago)
        expired_at = registration.offer_expires_at

        result = ExpireOffer.call(registration:, idempotency_key: "expire-offer")

        assert_predicate result, :success?
        registration.reload
        assert_equal "waitlisted", registration.status
        assert_operator registration.waitlisted_at, :>, original_waitlisted_at
        assert_equal 0, Catalog::InventoryReservation.where(registration_id: registration.id, status: "held").count
        event = Core::OutboxEvent.find_by!(
          aggregate_id: registration.id,
          event_type: "ticketing.registration.waitlist_offer_expired"
        )
        assert_equal registration.id, event.payload.fetch("registration_id")
        assert_equal expired_at.iso8601, event.payload.fetch("offer_expires_at")
      end

      test "offer acceptance defers the price decision until the buyer selects a currency" do
        free_type = create_ticket_type(capacity: 1, amount_minor: 0)
        free_registration = create_waitlisted_registration(ticket_type: free_type)
        assert_predicate OfferNext.call(ticket_type: free_type, idempotency_key: "offer-free"), :success?
        assert_equal "requires_order", free_registration.reload.next_action_snapshot
        free_result = AcceptOffer.call(
          registration: free_registration, actor: @attendee, idempotency_key: "accept-free"
        )

        assert_predicate free_result, :success?
        assert_equal "pending_payment", free_registration.reload.status
        assert_equal "requires_order", free_registration.next_action_snapshot
        assert_equal "held", Catalog::InventoryReservation.find_by!(registration_id: free_registration.id).status

        paid_type = create_ticket_type(capacity: 1, amount_minor: 1)
        paid_registration = create_waitlisted_registration(ticket_type: paid_type)
        assert_predicate OfferNext.call(ticket_type: paid_type, idempotency_key: "offer-paid"), :success?
        paid_result = AcceptOffer.call(
          registration: paid_registration, actor: @attendee, idempotency_key: "accept-paid"
        )

        assert_predicate paid_result, :success?
        assert_equal "pending_payment", paid_registration.reload.status
        assert_equal "requires_order", paid_registration.next_action_snapshot
      end

      private

      def create_ticket_type(capacity:, amount_minor:)
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @manager,
          product_attributes: { name: "Waitlist ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1, waitlist_enabled: true
          },
          price_attributes: { currency: "ETB", amount_minor:, active_from: Time.current },
          inventory_configuration: { mode: "event_wide", capacity: }
        ).value
        assert_predicate Catalog::Products::Activate.call(product:, actor: @manager), :success?
        product.reload.ticket_type
      end

      def create_waitlisted_registration(ticket_type:, package_quantity: 1, waitlisted_at: 1.minute.ago)
        Ticketing::Registration.create!(
          event: @event,
          ticket_type:,
          user: @attendee,
          created_by: @attendee,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity:,
          admissions_per_unit_snapshot: ticket_type.admissions_per_unit,
          party_size: package_quantity * ticket_type.admissions_per_unit,
          status: "waitlisted",
          waitlisted_at:,
          approved_at: Time.current,
          submitted_at: Time.current
        )
      end
    end

    class OfferNextConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @event = events_events(:ready_listing)
        @attendee = core_users(:attendee)
        @manager = core_users(:super_admin)
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @manager,
          product_attributes: { name: "Concurrent waitlist ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1, waitlist_enabled: true
          },
          price_attributes: { currency: "ETB", amount_minor: 1, active_from: Time.current },
          inventory_configuration: { mode: "event_wide", capacity: 1 }
        ).value
        assert_predicate Catalog::Products::Activate.call(product:, actor: @manager), :success?
        @ticket_type = product.reload.ticket_type
        @registration = Ticketing::Registration.create!(
          event: @event,
          ticket_type: @ticket_type,
          user: @attendee,
          created_by: @attendee,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "waitlisted",
          waitlisted_at: Time.current,
          approved_at: Time.current,
          submitted_at: Time.current
        )
      end

      teardown do
        Catalog::InventoryReservation.where(registration_id: @registration.id).delete_all
        Catalog::VenueCapacityReservation.where(registration_id: @registration.id).delete_all
        Ticketing::Registration.where(id: @registration.id).delete_all
        Core::AuditLog.where(auditable_id: [ @registration.id, @ticket_type.event_product_id ]).delete_all
        Core::OutboxEvent.where(aggregate_id: [ @registration.id, @ticket_type.event_product_id ]).delete_all
        Catalog::ProductInventory.where(event_product_id: @ticket_type.event_product_id).delete_all
        Catalog::ProductPrice.where(event_product_id: @ticket_type.event_product_id).delete_all
        Ticketing::TicketType.where(id: @ticket_type.id).delete_all
        Catalog::EventProduct.where(id: @ticket_type.event_product_id).delete_all
      end

      test "two workers cannot create duplicate offers" do
        race = run_database_race do |index|
          Ticketing::Waitlist::OfferNext.call(
            ticket_type: Ticketing::TicketType.find(@ticket_type.id),
            idempotency_key: "concurrent-offer-#{index}"
          )
        end
        results = race.results

        assert_empty race.errors, race.errors.inspect
        assert results.all?(&:success?)
        assert_equal 1, Ticketing::Registration.where(id: @registration.id, status: "offered").count
        assert_equal 1, Catalog::InventoryReservation.where(registration_id: @registration.id).count
      end
    end
  end
end
