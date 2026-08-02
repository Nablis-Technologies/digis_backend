# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Invitations
    class CreateTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @ticket_type = ticket_product.ticket_type
        @actor = core_users(:super_admin)
      end

      test "stores an encrypted delivery token and publishes only the invitation id" do
        result = Ticketing::Invitations::Create.call(
          ticket_type: @ticket_type,
          actor: @actor,
          attributes: { email: "guest@example.com", allowed_quantity: 1 },
          idempotency_key: "invitation-encryption"
        )

        assert result.success?, result.error&.message
        invitation = result.value.record
        assert_equal result.value.token, invitation.token
        stored_token = Ticketing::Invitation.connection.select_value(
          "SELECT token_ciphertext FROM ticketing_invitations WHERE id = '#{invitation.id}'"
        )
        refute_equal result.value.token, stored_token
        refute_includes stored_token, result.value.token

        outbox_event = Core::OutboxEvent.find_by(
          event_type: "ticketing.invitation.created",
          aggregate_id: invitation.id
        )
        assert outbox_event
        assert_equal({ "invitation_id" => invitation.id }, outbox_event.payload)
        refute outbox_event.payload.key?("token")
      end

      test "requires an idempotency key" do
        result = Ticketing::Invitations::Create.call(
          ticket_type: @ticket_type,
          actor: @actor,
          attributes: { email: "missing-key@example.com" },
          idempotency_key: nil
        )

        assert result.failure?
        assert_match(/idempotency key/i, result.error.message)
      end

      test "replays the original token without creating another invitation" do
        subject = lambda do
          Ticketing::Invitations::Create.call(
            ticket_type: @ticket_type,
            actor: @actor,
            attributes: { email: "replay@example.com", allowed_quantity: 1 },
            idempotency_key: "invitation-replay"
          )
        end

        first = subject.call
        second = subject.call

        assert first.success?, first.error&.message
        assert second.success?, second.error&.message
        assert_equal first.value.record.id, second.value.record.id
        assert_equal first.value.token, second.value.token
        assert_equal 1, Ticketing::Invitation.where(ticket_type_id: @ticket_type.id).count
        assert_equal 1, Core::OutboxEvent.where(
          event_type: "ticketing.invitation.created", aggregate_id: first.value.record.id
        ).count
        assert_equal 1, Core::AuditLog.where(
          action: "ticketing.invitation.created", auditable_id: first.value.record.id
        ).count
      end

      test "rejects an idempotency key reused for a different request" do
        first = Ticketing::Invitations::Create.call(
          ticket_type: @ticket_type,
          actor: @actor,
          attributes: { email: "first@example.com" },
          idempotency_key: "invitation-conflict"
        )
        second = Ticketing::Invitations::Create.call(
          ticket_type: @ticket_type,
          actor: @actor,
          attributes: { email: "second@example.com" },
          idempotency_key: "invitation-conflict"
        )

        assert first.success?, first.error&.message
        assert second.failure?
        assert_match(/different request/i, second.error.message)
        assert_equal 1, Ticketing::Invitation.where(ticket_type_id: @ticket_type.id).count
      end

      private

      def ticket_product
        Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @actor,
          product_attributes: { name: "Invitation ticket", type: "ticket" },
          ticket_type_attributes: {
            audience: "invitation", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1
          },
          inventory_configuration: { mode: "unlimited" }
        ).value
      end
    end
  end
end
