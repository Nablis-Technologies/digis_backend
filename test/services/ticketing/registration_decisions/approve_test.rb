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

      test "approval defers free versus paid fulfillment until currency selection" do
        ticket_type = create_ticket_type(approval_mode: "manual", amount_minor: 0)
        registration = create_registration(ticket_type:, status: "pending_approval")

        result = Approve.call(registration:, actor: @manager, idempotency_key: "approve-free-manual")

        assert_predicate result, :success?
        assert_equal "pending_payment", registration.reload.status
        assert_equal "requires_order", registration.next_action_snapshot
        assert_empty Ticketing::Ticket.where(registration_id: registration.id)
        assert_empty Catalog::InventoryReservation.where(registration_id: registration.id)
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

      test "reconsidered free registration remains pending until a currency is selected" do
        ticket_type = create_ticket_type(approval_mode: "manual", amount_minor: 0)
        registration = create_registration(ticket_type:, status: "rejected", rejected_at: Time.current)

        result = Reconsider.call(
          registration:, actor: @manager, decision: "approve", reason: "Review changed",
          idempotency_key: "reconsider-free-currency"
        )

        assert_predicate result, :success?
        assert_equal "pending_payment", registration.reload.status
        assert_equal "requires_order", registration.next_action_snapshot
        assert_empty Ticketing::Ticket.where(registration_id: registration.id)
        assert_empty Catalog::InventoryReservation.where(registration_id: registration.id)
      end

      test "a rejected registration cannot be approved without reconsideration" do
        ticket_type = create_ticket_type(approval_mode: "manual")
        registration = create_registration(ticket_type:, status: "rejected", rejected_at: Time.current)

        result = Approve.call(registration:, actor: @manager, idempotency_key: "approve-rejected")

        assert_predicate result, :failure?
        assert_equal "registration_not_approvable", result.error.code
      end

      test "reconsideration re-acquires the registration's access-code use" do
        ticket_type = create_ticket_type(approval_mode: "manual", audience: "access_code")
        access_code = create_access_code(ticket_type, max_uses: 5, used_count: 0)
        registration = create_registration(ticket_type:, status: "rejected", rejected_at: Time.current)
        registration.update!(access_code:)

        result = Reconsider.call(
          registration:, actor: @manager, decision: "approve", reason: "Review changed",
          idempotency_key: "reconsider-access-code"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "pending_payment", registration.reload.status
        assert_equal 1, access_code.reload.used_count
      end

      test "reconsideration remains rejected if its access code is exhausted" do
        ticket_type = create_ticket_type(approval_mode: "manual", audience: "access_code")
        access_code = create_access_code(ticket_type, max_uses: 1, used_count: 1)
        registration = create_registration(ticket_type:, status: "rejected", rejected_at: Time.current)
        registration.update!(access_code:)

        result = Reconsider.call(
          registration:, actor: @manager, decision: "approve", reason: "Review changed",
          idempotency_key: "reconsider-exhausted-access-code"
        )

        assert_predicate result, :failure?
        assert_equal "rejected", registration.reload.status
        assert_equal 1, access_code.reload.used_count
        assert_nil registration.approved_at
        assert_not Core::AuditLog.exists?(action: "ticketing.registration.reconsidered", auditable_id: registration.id)
      end

      test "reconsideration remains rejected if its invitation expired" do
        ticket_type = create_ticket_type(approval_mode: "manual", audience: "invitation")
        invitation = create_invitation(ticket_type, expires_at: 1.minute.ago)
        registration = create_registration(ticket_type:, status: "rejected", rejected_at: Time.current)
        registration.update!(invitation:)

        result = Reconsider.call(
          registration:, actor: @manager, decision: "approve", reason: "Review changed",
          idempotency_key: "reconsider-expired-invitation"
        )

        assert_predicate result, :failure?
        assert_equal "rejected", registration.reload.status
        assert_equal "pending", invitation.reload.status
        assert_nil registration.approved_at
      end

      test "reconsidering rejection as rejection does not return proof twice" do
        ticket_type = create_ticket_type(approval_mode: "manual", audience: "access_code")
        access_code = create_access_code(ticket_type, max_uses: 5, used_count: 1)
        registration = create_registration(ticket_type:, status: "pending_approval")
        registration.update!(access_code:)

        rejected = Reject.call(
          registration:, actor: @manager, reason: "Initial rejection", idempotency_key: "reject-before-reconsider"
        )
        assert_predicate rejected, :success?, rejected.error&.message
        assert_equal 0, access_code.reload.used_count

        reconsidered = Reconsider.call(
          registration:, actor: @manager, decision: "reject", reason: "Still rejected",
          idempotency_key: "reconsider-as-reject"
        )

        assert_predicate reconsidered, :success?, reconsidered.error&.message
        assert_equal "rejected", registration.reload.status
        assert_equal 0, access_code.reload.used_count
      end

      test "does not approve a registration after event cancellation" do
        ticket_type = create_ticket_type(approval_mode: "manual")
        registration = create_registration(ticket_type:, status: "pending_approval")
        @event.update!(status: "cancelled")

        result = Approve.call(registration:, actor: @manager, idempotency_key: "approve-cancelled-event")

        assert_predicate result, :failure?
        assert_equal "event_cancelled", result.error.code
        assert_equal "pending_approval", registration.reload.status
      end

      private

      def create_ticket_type(approval_mode:, audience: "public", amount_minor: 1)
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @manager,
          product_attributes: { name: "Decision ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience:, approval_mode:, date_selection: "fixed", admissions_per_unit: 1
          },
          price_attributes: { currency: "ETB", amount_minor:, active_from: Time.current },
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

      def create_access_code(ticket_type, max_uses:, used_count:)
        raw_code = "DECISION-CODE-#{SecureRandom.hex(4)}"
        Ticketing::AccessCode.create!(
          ticket_type:,
          code_digest: Ticketing::AccessCode.code_digest_for(
            event_id: @event.id, code: raw_code
          ),
          max_uses:,
          used_count:,
          max_quantity_per_use: 1,
          active: true
        )
      end

      def create_invitation(ticket_type, expires_at:)
        email = "decision-invitation-#{SecureRandom.hex(4)}@example.com"
        raw_token = SecureRandom.hex(24)
        Ticketing::Invitation.create!(
          ticket_type:,
          created_by: @manager,
          invited_user: @attendee,
          email:,
          contact_digest: Ticketing::Invitation.contact_digest_for(
            event_id: @event.id, contact: email
          ),
          token: raw_token,
          token_digest: Ticketing::Invitation.token_digest_for(
            event_id: @event.id, token: raw_token
          ),
          allowed_quantity: 1,
          status: "pending",
          expires_at:
        )
      end
    end
  end
end
