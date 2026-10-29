# frozen_string_literal: true

require "test_helper"

module Ticketing
  module RegistrationDecisions
    class RejectTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @attendee = core_users(:attendee)
        @manager = core_users(:super_admin)
        @ticket_type = create_ticket_type(audience: "access_code")
        @registration = create_registration
      end

      test "rejection returns access-code quantity exactly once" do
        @registration.update!(access_code: create_access_code(used_count: 1))
        subject = -> { reject("reject-access-code") }

        assert_audit_idempotent(
          subject,
          action: "ticketing.registration.rejected",
          auditable_type: "Ticketing::Registration",
          auditable_id: @registration.id
        )

        assert_equal "rejected", @registration.reload.status
        assert_equal 0, @registration.access_code.reload.used_count
      end

      test "rejection reopens a valid invitation and keeps it bound to the registrant" do
        @ticket_type.update!(audience: "invitation")
        invitation = create_invitation
        @registration.update!(invitation:)

        result = reject("reject-invitation")

        assert_predicate result, :success?, result.error&.message
        assert_equal "rejected", @registration.reload.status
        assert_equal "pending", invitation.reload.status
        assert_equal @attendee.id, invitation.invited_user_id
      end

      private

      def reject(key)
        Reject.call(
          registration: @registration,
          actor: @manager,
          reason: "Review decision",
          idempotency_key: key
        )
      end

      def create_ticket_type(audience:)
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @manager,
          product_attributes: { name: "Reject proof #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience:, approval_mode: "manual", date_selection: "fixed", admissions_per_unit: 1
          },
          price_attributes: { currency: "ETB", amount_minor: 100, active_from: Time.current },
          inventory_configuration: { mode: "unlimited" }
        )
        assert_predicate product, :success?, product.error&.message
        assert_predicate Catalog::Products::Activate.call(product: product.value, actor: @manager), :success?
        product.value.reload.ticket_type
      end

      def create_registration
        Ticketing::Registration.create!(
          event: @event,
          ticket_type: @ticket_type,
          user: @attendee,
          created_by: @attendee,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "pending_approval",
          next_action_snapshot: "awaiting_approval",
          submitted_at: Time.current
        )
      end

      def create_access_code(used_count:)
        raw_code = "REJECT-CODE-#{SecureRandom.hex(4)}"
        Ticketing::AccessCode.create!(
          ticket_type: @ticket_type,
          code_digest: Ticketing::AccessCode.code_digest_for(
            event_id: @event.id, code: raw_code
          ),
          max_uses: 5,
          used_count:,
          max_quantity_per_use: 1,
          active: true
        )
      end

      def create_invitation
        email = "reject-proof-#{SecureRandom.hex(4)}@example.com"
        raw_token = SecureRandom.hex(24)
        Ticketing::Invitation.create!(
          ticket_type: @ticket_type,
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
          status: "accepted",
          accepted_at: Time.current
        )
      end
    end
  end
end
