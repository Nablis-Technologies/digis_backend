# frozen_string_literal: true

require "test_helper"

module Ticketing
  class InvitationTest < ActiveSupport::TestCase
    setup do
      @ticket_type = create_ticket_product.ticket_type
      @creator = core_users(:super_admin)
    end

    test "an email or phone contact is required" do
      invitation = Ticketing::Invitation.new(
        ticket_type: @ticket_type,
        created_by: @creator,
        contact_digest: "deadbeef",
        token_digest: "token1"
      )
      assert invitation.invalid?
      assert_includes invitation.errors[:base], "an email or phone contact is required"
    end

    test "contact and token digests are stored and token is unique" do
      raw_token = SecureRandom.hex(16)
      event_id = @ticket_type.event_product.event_id
      invitation = Ticketing::Invitation.create!(
        ticket_type: @ticket_type,
        created_by: @creator,
        email: "Guest@example.com",
        contact_digest: Ticketing::Invitation.contact_digest_for(event_id:, contact: "Guest@example.com"),
        token_digest: Ticketing::Invitation.token_digest_for(event_id:, token: raw_token),
        token: raw_token,
        allowed_quantity: 2
      )

      assert invitation.persisted?
      assert_equal "Guest@example.com", invitation.email
      assert_equal raw_token, invitation.token
      stored_token = Ticketing::Invitation.connection.select_value(
        "SELECT token_ciphertext FROM ticketing_invitations WHERE id = '#{invitation.id}'"
      )
      refute_equal raw_token, stored_token
      refute_includes stored_token, raw_token
      assert invitation.phone_ciphertext.blank?

      duplicate = Ticketing::Invitation.new(
        ticket_type: @ticket_type,
        created_by: @creator,
        email: "other@example.com",
        contact_digest: "other",
        token_digest: invitation.token_digest
      )
      assert duplicate.invalid?
      assert_includes duplicate.errors[:token_digest], "has already been taken"
    end

    test "contact is normalized (downcased) before digesting" do
      event_id = @ticket_type.event_product.event_id
      digest_a = Ticketing::Invitation.contact_digest_for(event_id:, contact: "Guest@example.com")
      digest_b = Ticketing::Invitation.contact_digest_for(event_id:, contact: "guest@example.com")
      assert_equal digest_a, digest_b
    end

    test "status allowlist" do
      invitation = Ticketing::Invitation.new(
        ticket_type: @ticket_type,
        created_by: @creator,
        email: "g@example.com",
        contact_digest: "x",
        token_digest: "t",
        status: "weird"
      )
      assert invitation.invalid?
      assert_includes invitation.errors[:status], "is not included in the list"
    end

    private

    def create_ticket_product
      Catalog::Products::CreateDraft.call(
        event: events_events(:ready_listing),
        actor: core_users(:super_admin),
        product_attributes: { name: "VIP", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
    end
  end
end
