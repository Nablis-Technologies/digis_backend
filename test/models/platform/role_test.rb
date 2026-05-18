require "test_helper"

class PlatformRoleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "normalizes role codes" do
    role = Platform::Role.new(code: " mixed_case ", name: "Mixed")

    role.valid?

    assert_equal "MIXED_CASE", role.code
  end

  test "records audit entries inline" do
    role = platform_roles(:user)
    actor = platform_users(:super_admin)

    assert_difference("Platform::AuditLog.count", 1) do
      role.record_audit!(
        "role.updated",
        audited_changes: { "name" => { old: "User", new: "Attendee" } },
        actor: actor
      )
    end

    audit = role.audit_logs.recent.first
    assert_equal "role.updated", audit.action
    assert_equal actor, audit.actor
  end

  test "enqueues audit logging job" do
    role = platform_roles(:user)
    actor = platform_users(:super_admin)

    assert_enqueued_with(job: Platform::AuditLoggerJob) do
      role.record_audit_later!(
        "role.permissions_updated",
        audited_changes: { "permission_count" => { old: 1, new: 2 } },
        actor: actor
      )
    end
  end
end
