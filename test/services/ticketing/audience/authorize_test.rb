# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Audience
    class AuthorizeTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
      end

      test "public audience is always authorized" do
        tt = ticket_product(audience: "public").ticket_type
        result = Ticketing::Audience::Authorize.new(ticket_type: tt).call
        assert result.success?
        assert result.value[:authorized]
      end

      test "access_code audience rejects a missing code" do
        tt = ticket_product(audience: "access_code").ticket_type
        result = Ticketing::Audience::Authorize.new(ticket_type: tt).call
        assert result.failure?
      end

      test "access_code audience authorizes a valid, active, in-window code" do
        tt = ticket_product(audience: "access_code").ticket_type
        raw = "VIP-CODE"
        create_access_code(tt, raw, max_uses: 5)
        result = Ticketing::Audience::Authorize.new(ticket_type: tt, access_code: raw).call
        assert result.success?
        assert_equal "access_code", result.value[:reason]
      end

      test "access_code audience rejects an invalid code" do
        tt = ticket_product(audience: "access_code").ticket_type
        create_access_code(tt, "real", max_uses: 5)
        result = Ticketing::Audience::Authorize.new(ticket_type: tt, access_code: "wrong").call
        assert result.failure?
      end

      test "access_code audience rejects an exhausted code" do
        tt = ticket_product(audience: "access_code").ticket_type
        create_access_code(tt, "used-up", max_uses: 1, used_count: 1)
        result = Ticketing::Audience::Authorize.new(ticket_type: tt, access_code: "used-up").call
        assert result.failure?
      end

      test "access_code audience rejects an inactive code" do
        tt = ticket_product(audience: "access_code").ticket_type
        create_access_code(tt, "off", max_uses: 5, active: false)
        result = Ticketing::Audience::Authorize.new(ticket_type: tt, access_code: "off").call
        assert result.failure?
      end

      test "invitation audience authorizes a pending token" do
        tt = ticket_product(audience: "invitation").ticket_type
        raw = SecureRandom.hex(16)
        create_invitation(tt, raw, status: "pending")
        result = Ticketing::Audience::Authorize.new(ticket_type: tt, invitation: raw).call
        assert result.success?
        assert_equal "invitation", result.value[:reason]
      end

      test "invitation audience rejects an already-accepted token" do
        tt = ticket_product(audience: "invitation").ticket_type
        raw = SecureRandom.hex(16)
        create_invitation(tt, raw, status: "accepted")
        result = Ticketing::Audience::Authorize.new(ticket_type: tt, invitation: raw).call
        assert result.failure?
      end

      test "code_or_invitation accepts either a code or a token" do
        tt = ticket_product(audience: "code_or_invitation").ticket_type
        create_access_code(tt, "code-only", max_uses: 5)
        create_invitation(tt, SecureRandom.hex(16), status: "pending")

        code_result = Ticketing::Audience::Authorize.new(ticket_type: tt, access_code: "code-only").call
        assert code_result.success?

        raw_token = SecureRandom.hex(16)
        create_invitation(tt, raw_token, status: "pending")
        token_result = Ticketing::Audience::Authorize.new(ticket_type: tt, invitation: raw_token).call
        assert token_result.success?
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

      def create_access_code(tt, raw, **overrides)
        max_uses = overrides.delete(:max_uses) || 5
        used_count = overrides.delete(:used_count) || 0
        Ticketing::AccessCode.create!(
          ticket_type: tt,
          code_digest: Ticketing::AccessCode.code_digest_for(
            event_id: tt.event_product.event_id, code: raw
          ),
          max_uses: max_uses,
          used_count: used_count,
          max_quantity_per_use: 1,
          active: true
        ).tap { |c| c.update!(overrides) if overrides.any? }
      end

      def create_invitation(tt, raw, **overrides)
        event_id = tt.event_product.event_id
        Ticketing::Invitation.create!(
          ticket_type: tt,
          created_by: core_users(:super_admin),
          email: "guest@example.com",
          contact_digest: Ticketing::Invitation.contact_digest_for(event_id:, contact: "guest@example.com"),
          token_digest: Ticketing::Invitation.token_digest_for(event_id:, token: raw),
          allowed_quantity: 1,
          status: "pending"
        ).tap { |i| i.update!(overrides) if overrides.any? }
      end
    end
  end
end
