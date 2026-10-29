# frozen_string_literal: true

require "test_helper"

module Ticketing
  module ComplimentaryIssuance
    class IssueTest < ActiveSupport::TestCase
      include Ticketing::ConsentTestHelpers

      setup do
        @event = events_events(:ready_listing)
        @recipient = core_users(:attendee)
        @manager = core_users(:super_admin)
      end

      test "issues a normal confirmed zero-charge registration through limits and inventory" do
        ticket_type = create_ticket_type

        result = Issue.call(
          ticket_type:, actor: @manager, phone: @recipient.phone, package_quantity: 1,
          reason: "accessibility", idempotency_key: "complimentary-issue"
        )

        assert_predicate result, :success?
        registration = result.value
        assert_equal "confirmed", registration.status
        assert_equal "organizer_complimentary", registration.source
        assert_equal @manager, registration.created_by
        assert_equal "accessibility", registration.complimentary_reason
        assert_equal 1, Catalog::ProductInventory.where(event_product: ticket_type.event_product).sum(:sold_count)
        assert_equal 1, Ticketing::PurchaseLimitAllocation.where(registration:).where(status: "committed").count
        assert_equal 1, Core::OutboxEvent.where(
          event_type: "ticketing.registration.issuance_ready", aggregate_id: registration.id
        ).count
      end

      test "is idempotent and does not create a second registration or issuance event" do
        ticket_type = create_ticket_type
        subject = -> do
          Issue.call(
            ticket_type:, actor: @manager, phone: @recipient.phone, package_quantity: 1,
            reason: "sponsor_guest", idempotency_key: "complimentary-replay"
          )
        end

        assert_idempotent(subject, counter: -> { Ticketing::Registration.count })
        assert_equal 1, Core::OutboxEvent.where(event_type: "ticketing.registration.issuance_ready").count
      end

      test "requires the controlled reason and manager authorization" do
        ticket_type = create_ticket_type

        missing_reason = Issue.call(
          ticket_type:, actor: @manager, phone: @recipient.phone, package_quantity: 1,
          reason: nil, idempotency_key: "complimentary-missing-reason"
        )
        unauthorized = Issue.call(
          ticket_type:, actor: @recipient, phone: @recipient.phone, package_quantity: 1,
          reason: "staff_guest", idempotency_key: "complimentary-unauthorized"
        )

        assert_predicate missing_reason, :failure?
        assert_equal "complimentary_reason_invalid", missing_reason.error.code
        assert_predicate unauthorized, :failure?
        assert_equal "complimentary_unauthorized", unauthorized.error.code
        assert_equal 0, Ticketing::Registration.count
      end

      test "resolves an unclaimed recipient phone to an unverified shadow user" do
        ticket_type = create_ticket_type
        phone = "251922000005"

        result = Issue.call(
          ticket_type:, actor: @manager, phone:, package_quantity: 1,
          reason: "community_partner", idempotency_key: "complimentary-shadow-user"
        )

        assert_predicate result, :success?
        assert_equal "+#{phone}", result.value.user.phone
        assert_nil result.value.user.verified_at
      end

      test "does not bypass a required buyer consent gate" do
        ticket_type = create_ticket_type
        @ticket_type = ticket_type
        create_consent_document(scope: "buyer", required: true, name: "Complimentary terms")

        result = Issue.call(
          ticket_type:, actor: @manager, phone: @recipient.phone, package_quantity: 1,
          reason: "accessibility", idempotency_key: "complimentary-required-consent"
        )

        assert_predicate result, :failure?
        assert_equal "missing_required_buyer_consent", result.error.code
        assert_equal 0, Ticketing::Registration.count
        assert_equal 0, Ticketing::RegistrationConsentRequirement.count
        assert_equal 0, Catalog::ProductInventory.where(event_product: ticket_type.event_product).sum(:sold_count)
      end

      test "does not issue a complimentary registration after event cancellation" do
        ticket_type = create_ticket_type
        @event.update!(status: "cancelled")

        result = Issue.call(
          ticket_type:, actor: @manager, phone: @recipient.phone, package_quantity: 1,
          reason: "accessibility", idempotency_key: "complimentary-cancelled-event"
        )

        assert_predicate result, :failure?
        assert_equal "event_cancelled", result.error.code
        assert_empty Ticketing::Registration.where(event: @event)
      end

      private

      def create_ticket_type
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @manager,
          product_attributes: { name: "Complimentary ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "invitation", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1, max_packages_per_user: 1
          },
          price_attributes: { currency: "ETB", amount_minor: 100, active_from: Time.current },
          inventory_configuration: { mode: "event_wide", capacity: 2 }
        ).value
        assert_predicate Catalog::Products::Activate.call(product:, actor: @manager), :success?
        product.reload.ticket_type
      end
    end
  end
end
