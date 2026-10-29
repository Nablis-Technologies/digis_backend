# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Registrations
    module AudienceProof
      class ReacquireTest < ActiveSupport::TestCase
        include Ticketing::ConsentTestHelpers

        setup do
          setup_consent_context(package_quantity: 2)
          @registration.update!(status: "rejected", rejected_at: Time.current)
        end

        test "reacquires an access-code use by its stored association and audits no secret" do
          assert_reacquire_service
          @ticket_type.update!(audience: "access_code")
          raw_code = "REACQUIRE-CODE-#{SecureRandom.hex(4)}"
          access_code = create_access_code(raw_code:, max_uses: 5, used_count: 0)
          @registration.update!(access_code:)
          transition_key = "ticketing-registration-reconsider-#{SecureRandom.hex(8)}"

          result = Reacquire.call(registration: @registration, transition_key:)

          assert_predicate result, :success?, result.error&.message
          assert_equal 2, access_code.reload.used_count
          audit = Core::AuditLog.where(
            auditable_type: "Ticketing::Registration",
            auditable_id: @registration.id,
            action: "ticketing.registration.audience_proof_reacquired"
          ).sole
          audit_payload = { metadata: audit.metadata, changes: audit.audited_changes }.to_json
          refute_includes audit_payload, raw_code
        end

        test "exhausted code cannot be reacquired and remains unchanged" do
          assert_reacquire_service
          @ticket_type.update!(audience: "access_code")
          access_code = create_access_code(
            raw_code: "REACQUIRE-EXHAUSTED-#{SecureRandom.hex(4)}",
            max_uses: 2,
            used_count: 1
          )
          @registration.update!(access_code:)

          result = Reacquire.call(
            registration: @registration,
            transition_key: "ticketing-registration-reconsider-exhausted-#{SecureRandom.hex(8)}"
          )

          assert_predicate result, :failure?
          assert_equal 1, access_code.reload.used_count
          assert_equal "rejected", @registration.reload.status
        end

        test "reclaims a pending invitation for its bound registration user" do
          assert_reacquire_service
          @ticket_type.update!(audience: "invitation")
          invitation = create_invitation(invited_user: @actor, status: "pending", allowed_quantity: 2)
          @registration.update!(access_code: nil, invitation:)

          result = Reacquire.call(
            registration: @registration,
            transition_key: "ticketing-registration-reconsider-invitation-#{SecureRandom.hex(8)}"
          )

          assert_predicate result, :success?, result.error&.message
          invitation.reload
          assert_equal "accepted", invitation.status
          assert_equal @actor.id, invitation.invited_user_id
          assert_not_nil invitation.accepted_at
        end

        test "expired or differently-bound invitations cannot be reacquired" do
          assert_reacquire_service
          @ticket_type.update!(audience: "invitation")
          invitation = create_invitation(
            invited_user: core_users(:support), status: "pending", allowed_quantity: 2,
            expires_at: 1.minute.ago
          )
          @registration.update!(access_code: nil, invitation:)

          result = Reacquire.call(
            registration: @registration,
            transition_key: "ticketing-registration-reconsider-expired-invitation-#{SecureRandom.hex(8)}"
          )

          assert_predicate result, :failure?
          assert_equal "pending", invitation.reload.status
          assert_equal core_users(:support).id, invitation.invited_user_id
          assert_equal "rejected", @registration.reload.status
        end

        test "audit failure rolls proof reacquisition back" do
          assert_reacquire_service
          @ticket_type.update!(audience: "access_code")
          access_code = create_access_code(
            raw_code: "REACQUIRE-AUDIT-#{SecureRandom.hex(4)}",
            max_uses: 5,
            used_count: 0
          )
          @registration.update!(access_code:)
          error = Core::BusinessError.new("audit unavailable", code: "audit_unavailable", status: :conflict)
          audit_result = Core::BaseService::Result.failure(error)

          with_audit_writer_failure(audit_result) do
            result = Reacquire.call(
              registration: @registration,
              transition_key: "ticketing-registration-reconsider-audit-failure-#{SecureRandom.hex(8)}"
            )

            assert_predicate result, :failure?
          end

          assert_equal 0, access_code.reload.used_count
          assert_equal "rejected", @registration.reload.status
        end

        private

        def assert_reacquire_service
          assert defined?(Ticketing::Registrations::AudienceProof::Reacquire),
            "expected the proof-reacquisition command"
        end

        def create_access_code(raw_code:, max_uses:, used_count:)
          Ticketing::AccessCode.create!(
            ticket_type: @ticket_type,
            code_digest: Ticketing::AccessCode.code_digest_for(
              event_id: @event.id, code: raw_code
            ),
            max_uses:,
            used_count:,
            max_quantity_per_use: 2,
            active: true
          )
        end

        def create_invitation(invited_user:, status:, allowed_quantity:, expires_at: nil)
          email = "audience-reacquire-#{SecureRandom.hex(4)}@example.com"
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
            allowed_quantity:,
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
