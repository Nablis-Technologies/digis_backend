# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Invitations
    class ClaimTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @ticket_type = ticket_product(audience: "invitation").ticket_type
        @raw = SecureRandom.hex(16)
        @event_id = @ticket_type.event_product.event_id
        @invitation = Ticketing::Invitation.create!(
          ticket_type: @ticket_type,
          created_by: core_users(:super_admin),
          email: "guest@example.com",
          contact_digest: Ticketing::Invitation.contact_digest_for(
            event_id: @event_id, contact: "guest@example.com"
          ),
          token_digest: Ticketing::Invitation.token_digest_for(event_id: @event_id, token: @raw),
          token: @raw,
          allowed_quantity: 1,
          status: "pending"
        )
      end

      test "valid pending token marks the invitation accepted" do
        result = Ticketing::Invitations::Claim.new(
          ticket_type: @ticket_type, raw_token: @raw
        ).call
        assert result.success?
        assert_equal "accepted", result.value.status
        assert_not_nil result.value.accepted_at
      end

      test "rejects a non-invitation object even when its id matches an invitation" do
        impostor = Struct.new(:id).new(@invitation.id)

        result = Ticketing::Invitations::Claim.new(
          ticket_type: @ticket_type, invitation: impostor
        ).call

        assert_predicate result, :failure?
        assert_equal "pending", @invitation.reload.status
      end

      test "invalid token fails" do
        result = Ticketing::Invitations::Claim.new(
          ticket_type: @ticket_type, raw_token: "bogus"
        ).call
        assert result.failure?
        assert_equal "pending", @invitation.reload.status
      end

      test "already-accepted token fails" do
        @invitation.update!(status: "accepted", accepted_at: Time.current)
        result = Ticketing::Invitations::Claim.new(
          ticket_type: @ticket_type, raw_token: @raw
        ).call
        assert result.failure?
      end

      test "expired token fails" do
        @invitation.update!(expires_at: 1.day.ago)
        result = Ticketing::Invitations::Claim.new(
          ticket_type: @ticket_type, raw_token: @raw
        ).call
        assert result.failure?
      end

      test "quantity above invitation allowance fails without accepting it" do
        result = Ticketing::Invitations::Claim.new(
          ticket_type: @ticket_type, raw_token: @raw, quantity: 2
        ).call

        assert result.failure?
        assert_equal "pending", @invitation.reload.status
      end

      test "a bound invitation cannot be claimed by another user" do
        invited_user = core_users(:attendee)
        claimant = core_users(:support)
        @invitation.update!(invited_user: invited_user)

        result = Ticketing::Invitations::Claim.new(
          ticket_type: @ticket_type, raw_token: @raw, user: claimant
        ).call

        assert_predicate result, :failure?
        assert_equal "pending", @invitation.reload.status
        assert_equal invited_user.id, @invitation.invited_user_id
      end

      private

      def ticket_product(audience:, **ticket_attrs)
        Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "VIP", type: "ticket" },
          ticket_type_attributes: {
            audience: audience, approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1
          }.merge(ticket_attrs),
          inventory_configuration: { mode: "unlimited" }
        ).value
      end
    end
  end
end
