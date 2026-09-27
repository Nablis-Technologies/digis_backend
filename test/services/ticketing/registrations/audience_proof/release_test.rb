# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Registrations
    module AudienceProof
      class ReleaseTest < ActiveSupport::TestCase
        include Ticketing::ConsentTestHelpers

        setup do
          setup_consent_context(package_quantity: 2)
          @ticket_type.update!(audience: "access_code")
          @raw_code = "RELEASE-CODE-#{SecureRandom.hex(4)}"
          @access_code = create_access_code(used_count: 2)
          @registration.update!(access_code: @access_code)
        end

        test "returns one access-code use per package and audits no secret" do
          assert_release_service

          result = Release.call(
            registration: @registration,
            reason: "buyer_requested",
            transition_key: "ticketing-registration-release-#{SecureRandom.hex(8)}"
          )

          assert_predicate result, :success?, result.error&.message
          assert_equal 0, @access_code.reload.used_count
          audit = Core::AuditLog.where(
            auditable_type: "Ticketing::Registration",
            auditable_id: @registration.id,
            action: "ticketing.registration.audience_proof_released"
          ).sole
          audit_payload = { metadata: audit.metadata, changes: audit.audited_changes }.to_json
          refute_includes audit_payload, @raw_code
        end

        test "counter underflow fails without decrementing the access code" do
          assert_release_service
          @access_code.update!(used_count: 1)

          result = Release.call(
            registration: @registration,
            reason: "buyer_requested",
            transition_key: "ticketing-registration-underflow-#{SecureRandom.hex(8)}"
          )

          assert_predicate result, :failure?
          assert_equal "audience_proof_release_inconsistent", result.error.code
          assert_equal 1, @access_code.reload.used_count
        end

        test "audit failure rolls access-code restoration back" do
          assert_release_service
          error = Core::BusinessError.new("audit unavailable", code: "audit_unavailable", status: :conflict)
          audit_result = Core::BaseService::Result.failure(error)

          with_audit_writer_failure(audit_result) do
            result = Release.call(
              registration: @registration,
              reason: "buyer_requested",
              transition_key: "ticketing-registration-audit-failure-#{SecureRandom.hex(8)}"
            )

            assert_predicate result, :failure?
          end

          assert_equal 2, @access_code.reload.used_count
        end

        test "reopens only a valid accepted invitation and preserves its claimant" do
          assert_release_service
          @ticket_type.update!(audience: "invitation")
          invitation = create_invitation(status: "accepted", invited_user: @actor)
          @registration.update!(access_code: nil, invitation:)

          result = Release.call(
            registration: @registration,
            reason: "organizer_rejected",
            transition_key: "ticketing-registration-invitation-release-#{SecureRandom.hex(8)}"
          )

          assert_predicate result, :success?, result.error&.message
          invitation.reload
          assert_equal "pending", invitation.status
          assert_nil invitation.accepted_at
          assert_equal @actor.id, invitation.invited_user_id
        end

        test "marks an accepted invitation expired rather than reopening it past expiry" do
          assert_release_service
          @ticket_type.update!(audience: "invitation")
          invitation = create_invitation(
            status: "accepted", invited_user: @actor, expires_at: 1.minute.ago
          )
          @registration.update!(access_code: nil, invitation:)

          result = Release.call(
            registration: @registration,
            reason: "organizer_rejected",
            transition_key: "ticketing-registration-expired-invitation-#{SecureRandom.hex(8)}"
          )

          assert_predicate result, :success?, result.error&.message
          assert_equal "expired", invitation.reload.status
        end

        test "does not reopen a revoked invitation" do
          assert_release_service
          @ticket_type.update!(audience: "invitation")
          invitation = create_invitation(status: "revoked", invited_user: @actor)
          @registration.update!(access_code: nil, invitation:)

          result = Release.call(
            registration: @registration,
            reason: "organizer_rejected",
            transition_key: "ticketing-registration-revoked-invitation-#{SecureRandom.hex(8)}"
          )

          assert_predicate result, :success?, result.error&.message
          assert_equal "revoked", invitation.reload.status
        end

        private

        def assert_release_service
          assert defined?(Ticketing::Registrations::AudienceProof::Release),
            "expected the proof-release command"
        end

        def create_access_code(used_count:)
          Ticketing::AccessCode.create!(
            ticket_type: @ticket_type,
            code_digest: Ticketing::AccessCode.code_digest_for(
              event_id: @event.id, code: @raw_code
            ),
            max_uses: 5,
            used_count:,
            max_quantity_per_use: 2,
            active: true
          )
        end

        def create_invitation(status:, invited_user:, expires_at: nil)
          email = "audience-release-#{SecureRandom.hex(4)}@example.com"
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
            allowed_quantity: 2,
            status:,
            accepted_at: status == "accepted" ? Time.current : nil,
            expires_at:
          )
        end

        def with_audit_writer_failure(result)
          writer = Core::Audit::Record.singleton_class
          writer.define_method(:call) { |*_arguments, **_keywords| result }
          yield
        ensure
          writer.remove_method(:call)
        end
      end
    end
  end
end
