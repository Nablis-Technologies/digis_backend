# frozen_string_literal: true

require "test_helper"

class CoreAuditLoggerJobTest < ActiveJob::TestCase
  setup do
    @role = core_roles(:core_admin)
    @actor = core_users(:super_admin)
    Core::AuditLog.delete_all
  end

  test "writes a normalized payload through the single recorder" do
    assert_difference("Core::AuditLog.count", 1) do
      Core::AuditLoggerJob.perform_now(
        audit_key: "role.updated:1",
        action: "role.updated",
        auditable_type: @role.class.name,
        auditable_id: @role.id,
        actor_type: @actor.class.name,
        actor_id: @actor.id,
        audited_changes: { "description" => { old: "Old", new: "New" } },
        metadata: { "source" => "test" },
        request_uuid: "uuid-1",
        ip_address: "127.0.0.1",
        user_agent: "Mozilla"
      )
    end

    audit = Core::AuditLog.recent.first
    assert_equal @role, audit.auditable
    assert_equal @actor, audit.actor
    assert_equal "role.updated", audit.action
    assert_equal "test", audit.metadata["source"]
  end

  test "replay of the same payload is idempotent" do
    payload = {
      audit_key: "role.updated:replay",
      action: "role.updated",
      auditable_type: @role.class.name,
      auditable_id: @role.id,
      audited_changes: { "name" => { old: "A", new: "B" } }
    }

    assert_difference("Core::AuditLog.count", 1) do
      Core::AuditLoggerJob.perform_now(**payload)
      Core::AuditLoggerJob.perform_now(**payload)
    end
  end

  test "retries safely when the auditable record is gone" do
    role_id = @role.id
    @role.destroy!

    assert_difference("Core::AuditLog.count", 1) do
      Core::AuditLoggerJob.perform_now(
        audit_key: "deleted.role:1",
        action: "role.deleted",
        auditable_type: "Core::Role",
        auditable_id: role_id,
        audited_changes: { "name" => { old: "A", new: nil } }
      )
    end

    audit = Core::AuditLog.recent.first
    assert_nil audit.auditable
    assert_equal "Core::Role", audit.auditable_type
    assert_equal role_id, audit.auditable_id
  end
end
