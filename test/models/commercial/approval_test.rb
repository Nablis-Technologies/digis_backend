# frozen_string_literal: true

require "test_helper"

module Commercial
  class ApprovalTest < ActiveSupport::TestCase
    include Commercial::GovernanceTestHelpers

    setup do
      @version = create_simulatable_version(code: "approval_model")
    end

    test "allows only commercial lifecycle targets" do
      approval = build_approval(target_type: "Core::User")

      assert_not approval.valid?
      assert_includes approval.errors[:target_type], "is not included in the list"
    end

    test "stores append-only approval evidence" do
      approval = Commercial::Approval.create!(
        target: @version,
        decision: "approved",
        reason: "Definition reviewed",
        definition_digest: @version.definition_digest,
        actor: core_users(:super_admin),
        decided_at: Time.current,
        idempotency_key_digest: "3" * 64,
        request_fingerprint: "4" * 64
      )

      assert_raises(ActiveRecord::ReadOnlyRecord) { approval.update!(reason: "Changed") }
    end

    private

    def build_approval(attributes = {})
      Commercial::Approval.new(
        {
          target_type: "Commercial::FeeScheduleVersion",
          target_id: @version.id,
          decision: "approved",
          reason: "Definition reviewed",
          definition_digest: @version.definition_digest,
          actor: core_users(:super_admin),
          decided_at: Time.current,
          idempotency_key_digest: "5" * 64,
          request_fingerprint: "6" * 64
        }.merge(attributes)
      )
    end
  end
end
