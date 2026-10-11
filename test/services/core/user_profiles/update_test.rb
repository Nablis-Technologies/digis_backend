require "test_helper"

module Core
  module UserProfiles
    class UpdateTest < ActiveSupport::TestCase
      setup do
        @user = core_users(:attendee)
        @request = Struct.new(:request_id, :remote_ip, :user_agent).new(
          "profile-update-request",
          "192.0.2.10",
          "profile-update-test"
        )
      end

      test "profile update is audit-idempotent and omits submitted names from audit" do
        outcomes = []
        operation = -> do
          outcomes << update_profile(
            idempotency_key: "profile-update-audit-replay",
            attributes: { first_name: "Mimi", last_name: "Abebe" }
          )
        end

        assert_audit_idempotent(
          operation,
          action: "core.user.profile_updated",
          auditable_type: "Core::UserProfile",
          auditable_id: -> { @user.reload.profile&.id }
        )

        assert_predicate outcomes.first, :success?
        audit = Core::AuditLog.find_by!(
          action: "core.user.profile_updated",
          auditable_type: "Core::UserProfile",
          auditable_id: @user.reload.profile.id
        )
        refute_includes audit.audited_changes.to_json, "Mimi"
        refute_includes audit.audited_changes.to_json, "Abebe"
        refute_includes audit.metadata.to_json, "Mimi"
        refute_includes audit.metadata.to_json, "Abebe"
      end

      test "same idempotency key with changed names conflicts without changing profile" do
        first = update_profile(
          idempotency_key: "profile-update-changed-payload",
          attributes: { first_name: "Mimi", last_name: "Abebe" }
        )
        replay = update_profile(
          idempotency_key: "profile-update-changed-payload",
          attributes: { first_name: "Selam", last_name: "Abebe" }
        )

        assert_predicate first, :success?
        assert_predicate replay, :failure?
        assert_equal "idempotency_conflict", replay.error.code
        assert_equal "Mimi", @user.reload.profile.first_name
      end

      private

      def update_profile(idempotency_key:, attributes:)
        Core::UserProfiles::Update.call(
          user: @user,
          attributes: attributes,
          idempotency_key: idempotency_key,
          request: @request
        )
      end
    end
  end
end
