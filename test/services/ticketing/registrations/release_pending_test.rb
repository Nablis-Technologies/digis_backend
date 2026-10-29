# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Registrations
    class ReleasePendingTest < ActiveSupport::TestCase
      include Ticketing::ConsentTestHelpers

      setup do
        setup_consent_context
      end

      test "cancels a buyer-owned pending registration and audits replay once" do
        subject = -> do
          ReleasePending.call(
            registration: @registration,
            buyer: @actor,
            idempotency_key: "release-pending-registration"
          )
        end

        assert_audit_idempotent(
          subject,
          action: "ticketing.registration.pending_released",
          auditable_type: "Ticketing::Registration",
          auditable_id: @registration.id
        )
        assert_equal "cancelled", @registration.reload.status
        assert_not_nil @registration.cancelled_at
      end

      test "rejects release by another buyer" do
        result = ReleasePending.call(
          registration: @registration,
          buyer: core_users(:support),
          idempotency_key: "release-pending-forbidden"
        )

        assert_predicate result, :failure?
        assert_equal "registration_not_owned", result.error.code
        assert_equal "pending_payment", @registration.reload.status
      end

      test "returns access-code quantity exactly once with a replayed buyer release" do
        @ticket_type.update!(audience: "access_code")
        access_code = create_access_code(used_count: @registration.package_quantity)
        @registration.update!(access_code:)
        subject = -> do
          ReleasePending.call(
            registration: @registration,
            buyer: @actor,
            idempotency_key: "release-pending-access-code"
          )
        end

        assert_audit_idempotent(
          subject,
          action: "ticketing.registration.pending_released",
          auditable_type: "Ticketing::Registration",
          auditable_id: @registration.id
        )

        assert_equal "cancelled", @registration.reload.status
        assert_equal 0, access_code.reload.used_count
      end

      test "reopens a valid invitation when the buyer releases registration" do
        @ticket_type.update!(audience: "invitation")
        invitation = create_invitation(status: "accepted", invited_user: @actor)
        @registration.update!(invitation:)

        result = ReleasePending.call(
          registration: @registration,
          buyer: @actor,
          idempotency_key: "release-pending-invitation"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "cancelled", @registration.reload.status
        assert_equal "pending", invitation.reload.status
        assert_equal @actor.id, invitation.invited_user_id
      end

      private

      def create_access_code(used_count:)
        raw_code = "RELEASE-PENDING-#{SecureRandom.hex(4)}"
        Ticketing::AccessCode.create!(
          ticket_type: @ticket_type,
          code_digest: Ticketing::AccessCode.code_digest_for(
            event_id: @event.id, code: raw_code
          ),
          max_uses: 5,
          used_count:,
          max_quantity_per_use: @registration.package_quantity,
          active: true
        )
      end

      def create_invitation(status:, invited_user:)
        email = "release-pending-#{SecureRandom.hex(4)}@example.com"
        raw_token = SecureRandom.hex(24)
        Ticketing::Invitation.create!(
          ticket_type: @ticket_type,
          created_by: core_users(:super_admin),
          invited_user:,
          email:,
          contact_digest: Ticketing::Invitation.contact_digest_for(
            event_id: @event.id, contact: email
          ),
          token: raw_token,
          token_digest: Ticketing::Invitation.token_digest_for(
            event_id: @event.id, token: raw_token
          ),
          allowed_quantity: @registration.package_quantity,
          status:,
          accepted_at: status == "accepted" ? Time.current : nil
        )
      end
    end
  end
end
