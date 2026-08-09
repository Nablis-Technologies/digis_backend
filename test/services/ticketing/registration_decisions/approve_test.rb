# frozen_string_literal: true

require "test_helper"

module Ticketing
  module RegistrationDecisions
    class ApproveTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @attendee = core_users(:attendee)
        @manager = core_users(:super_admin)
      end

      test "manually approves a pending registration and records the reviewer" do
        ticket_type = create_ticket_type(approval_mode: "manual")
        registration = create_registration(ticket_type:, status: "pending_approval")

        result = Approve.call(registration:, actor: @manager, idempotency_key: "approve-manual")

        assert_predicate result, :success?
        registration.reload
        assert_equal "pending_payment", registration.status
        assert_equal @manager, registration.reviewed_by
        assert_not_nil registration.approved_at
        assert_nil registration.rejected_at
        assert_equal "requires_order", registration.next_action_snapshot
      end

      test "automatic approval does not require a reviewer" do
        ticket_type = create_ticket_type(approval_mode: "automatic")
        registration = create_registration(ticket_type:, status: "pending_payment")

        result = Approve.call(registration:, actor: nil, idempotency_key: "approve-automatic")

        assert_predicate result, :success?
        registration.reload
        assert_equal "pending_payment", registration.status
        assert_not_nil registration.approved_at
        assert_nil registration.reviewed_by
      end

      test "reconsideration replaces a rejection and is audit-idempotent" do
        ticket_type = create_ticket_type(approval_mode: "manual")
        registration = create_registration(ticket_type:, status: "pending_approval")
        assert_predicate Reject.call(
          registration:, actor: @manager, reason: "Capacity review", idempotency_key: "reject-registration"
        ), :success?

        subject = -> do
          Reconsider.call(
            registration:, actor: @manager, decision: "approve", reason: "Capacity restored",
            idempotency_key: "reconsider-registration"
          )
        end

        assert_audit_idempotent(
          subject,
          action: "ticketing.registration.reconsidered",
          auditable_type: registration.class.name,
          auditable_id: registration.id
        )
        registration.reload
        assert_equal "pending_payment", registration.status
        assert_not_nil registration.approved_at
        assert_nil registration.rejected_at
        assert_equal @manager, registration.reviewed_by
      end

      test "a rejected registration cannot be approved without reconsideration" do
        ticket_type = create_ticket_type(approval_mode: "manual")
        registration = create_registration(ticket_type:, status: "rejected", rejected_at: Time.current)

        result = Approve.call(registration:, actor: @manager, idempotency_key: "approve-rejected")

        assert_predicate result, :failure?
        assert_equal "registration_not_approvable", result.error.code
      end

      private

      def create_ticket_type(approval_mode:)
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @manager,
          product_attributes: { name: "Decision ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode:, date_selection: "fixed", admissions_per_unit: 1
          },
          price_attributes: { currency: "ETB", amount_minor: 1, active_from: Time.current },
          inventory_configuration: { mode: "unlimited" }
        ).value
        assert_predicate Catalog::Products::Activate.call(product:, actor: @manager), :success?
        product.reload.ticket_type
      end

      def create_registration(ticket_type:, status:, rejected_at: nil)
        Ticketing::Registration.create!(
          event: @event,
          ticket_type:,
          user: @attendee,
          created_by: @attendee,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity: 1,
          admissions_per_unit_snapshot: ticket_type.admissions_per_unit,
          party_size: ticket_type.admissions_per_unit,
          status:,
          rejected_at:,
          submitted_at: Time.current
        )
      end
    end
  end
end
