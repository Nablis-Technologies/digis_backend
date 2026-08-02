# frozen_string_literal: true

require "test_helper"

module Ticketing
  class DeliverInvitationJobTest < ActiveJob::TestCase
    setup do
      @event = events_events(:ready_listing)
      @ticket_type = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Delivery ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "invitation", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value.ticket_type
      @token = SecureRandom.hex(16)
      @invitation = Ticketing::Invitation.create!(
        ticket_type: @ticket_type,
        created_by: core_users(:super_admin),
        email: "guest@example.com",
        contact_digest: Ticketing::Invitation.contact_digest_for(
          event_id: @event.id, contact: "guest@example.com"
        ),
        token_digest: Ticketing::Invitation.token_digest_for(event_id: @event.id, token: @token),
        token: @token
      )
    end

    test "passes the decrypted token to the injected sender" do
      delivered = nil
      previous_sender = Rails.application.config.x.invitation_delivery_sender
      Rails.application.config.x.invitation_delivery_sender = lambda do |invitation:, token:|
        delivered = [ invitation.id, token ]
      end

      Ticketing::DeliverInvitationJob.perform_now(@invitation.id)

      assert_equal [ @invitation.id, @invitation.token ], delivered
    ensure
      Rails.application.config.x.invitation_delivery_sender = previous_sender
    end

    test "defaults to no-op when no sender is configured" do
      previous_sender = Rails.application.config.x.invitation_delivery_sender
      Rails.application.config.x.invitation_delivery_sender = nil

      assert_nothing_raised { Ticketing::DeliverInvitationJob.perform_now(@invitation.id) }
    ensure
      Rails.application.config.x.invitation_delivery_sender = previous_sender
    end
  end
end
