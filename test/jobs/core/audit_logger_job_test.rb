require "test_helper"

class CoreAuditLoggerJobTest < ActiveJob::TestCase
  setup do
    @role = core_roles(:core_admin)
    @actor = core_users(:super_admin)
    # Clear any existing audit logs
    Core::AuditLog.delete_all
  end

  test "creates an audit log for the auditable record (legacy signature)" do
    assert_difference("Core::AuditLog.count", 1) do
      Core::AuditLoggerJob.perform_now(
        auditable_type: @role.class.name,
        auditable_id: @role.id,
        actor_type: @actor.class.name,
        actor_id: @actor.id,
        action: "role.updated",
        audited_changes: { "description" => { old: "Old", new: "New" } },
        metadata: { "source" => "test" }
      )
    end

    audit = Core::AuditLog.recent.first
    assert_equal @role, audit.auditable
    assert_equal @actor, audit.actor
    assert_equal "role.updated", audit.action
    assert_equal "test", audit.metadata["source"]
  end

  test "handles advanced signature with before/after snapshots" do
    before_main = {
      id: @role.id,
      type: @role.class.name,
      attributes: { name: "Old Name", description: "Old Desc", code: "OLD" },
      timestamp: Time.current.to_f
    }

    after_main = {
      id: @role.id,
      type: @role.class.name,
      attributes: { name: "New Name", description: "Old Desc", code: "OLD" },
      timestamp: Time.current.to_f
    }

    assert_difference("Core::AuditLog.count", 1) do
      Core::AuditLoggerJob.perform_now(
        record_id: @role.id,
        record_type: @role.class.name,
        before_main: before_main,
        after_main: after_main,
        before_associated: {},
        after_associated: {},
        action_name: "update",
        controller_name: "roles",
        configs: [ { only: [], except: [], on: [ :update ], associated: {} } ],
        actor_id: @actor.id,
        actor_type: @actor.class.name,
        request_uuid: "uuid123",
        ip_address: "127.0.0.1",
        user_agent: "Mozilla"
      )
    end

    audit = Core::AuditLog.recent.first
    assert_not_nil audit
    changes = audit.audited_changes.with_indifferent_access
    assert changes.is_a?(Hash), "Changes should be a hash, got #{changes.class}"
    assert changes["main"].present?, "Main changes should be present"
    assert_includes changes["main"]["changes"].keys.map(&:to_s), "name"
  end

  test "skips audit when no changes detected" do
    before_main = {
      id: @role.id,
      type: @role.class.name,
      attributes: { name: "Name", description: "Desc", code: "CODE" },
      timestamp: Time.current.to_f
    }

    after_main = before_main.dup

    assert_no_difference("Core::AuditLog.count") do
      Core::AuditLoggerJob.perform_now(
        record_id: @role.id,
        record_type: @role.class.name,
        before_main: before_main,
        after_main: after_main,
        before_associated: {},
        after_associated: {},
        action_name: "update",
        controller_name: "roles",
        configs: [ { only: [], except: [], on: [ :update ], associated: {} } ]
      )
    end
  end

  test "filters fields with only" do
    before_main = {
      id: @role.id,
      type: @role.class.name,
      attributes: { name: "Old", description: "Old Desc", code: "CODE" },
      timestamp: Time.current.to_f
    }

    after_main = {
      id: @role.id,
      type: @role.class.name,
      attributes: { name: "New", description: "New Desc", code: "CODE" },
      timestamp: Time.current.to_f
    }

    assert_difference("Core::AuditLog.count", 1) do
      Core::AuditLoggerJob.perform_now(
        record_id: @role.id,
        record_type: @role.class.name,
        before_main: before_main,
        after_main: after_main,
        before_associated: {},
        after_associated: {},
        action_name: "update",
        controller_name: "roles",
        configs: [ { only: [ :name ], except: [], on: [ :update ], associated: {} } ]
      )
    end

    audit = Core::AuditLog.recent.first
    assert_not_nil audit, "Audit should be created"
    changes = audit.audited_changes.with_indifferent_access
    assert changes.is_a?(Hash), "Changes should be a hash"
    assert changes["main"].present?, "Main changes should be present"
    assert_includes changes["main"]["changes"].keys.map(&:to_s), "name"
    assert_not_includes changes["main"]["changes"].keys.map(&:to_s), "description"
  end

  test "filters fields with except" do
    before_main = {
      id: @role.id,
      type: @role.class.name,
      attributes: { name: "Old", description: "Old Desc", code: "CODE" },
      timestamp: Time.current.to_f
    }

    after_main = {
      id: @role.id,
      type: @role.class.name,
      attributes: { name: "New", description: "New Desc", code: "CODE" },
      timestamp: Time.current.to_f
    }

    assert_difference("Core::AuditLog.count", 1) do
      Core::AuditLoggerJob.perform_now(
        record_id: @role.id,
        record_type: @role.class.name,
        before_main: before_main,
        after_main: after_main,
        before_associated: {},
        after_associated: {},
        action_name: "update",
        controller_name: "roles",
        configs: [ { only: [], except: [ :description ], on: [ :update ], associated: {} } ]
      )
    end

    audit = Core::AuditLog.recent.first
    assert_not_nil audit, "Audit should be created"
    changes = audit.audited_changes.with_indifferent_access
    assert changes.is_a?(Hash), "Changes should be a hash"
    assert_includes changes["main"]["changes"].keys.map(&:to_s), "name"
    assert_not_includes changes["main"]["changes"].keys.map(&:to_s), "description"
  end

  test "discards job when record not found" do
    assert_no_difference("Core::AuditLog.count") do
      Core::AuditLoggerJob.perform_now(
        auditable_type: "Role",
        auditable_id: 999_999,
        action: "deleted",
        audited_changes: {},
        metadata: {}
      )
    end
  end

  test "uses custom action label from config - with changes" do
    before_main = {
      id: @role.id,
      type: @role.class.name,
      attributes: { name: "Old Name", code: "CODE" },
      timestamp: Time.current.to_f
    }

    after_main = {
      id: @role.id,
      type: @role.class.name,
      attributes: { name: "New Name", code: "CODE" },
      timestamp: Time.current.to_f
    }

    assert_difference("Core::AuditLog.count", 1) do
      Core::AuditLoggerJob.perform_now(
        record_id: @role.id,
        record_type: @role.class.name,
        before_main: before_main,
        after_main: after_main,
        before_associated: {},
        after_associated: {},
        action_name: "update",
        controller_name: "roles",
        configs: [ { only: [], except: [], on: [ :update ], action: { update: "published" }, associated: {} } ]
      )
    end

    audit = Core::AuditLog.recent.first
    assert_equal "published", audit.action
  end

  test "handles create action with nil before_main" do
    new_role = Core::Role.create!(name: "Test Role", description: "Test", code: "TEST")

    before_main = nil
    after_main = {
      id: new_role.id,
      type: new_role.class.name,
      attributes: { name: "Test Role", description: "Test", code: "TEST" },
      timestamp: Time.current.to_f
    }

    assert_difference("Core::AuditLog.count", 1) do
      Core::AuditLoggerJob.perform_now(
        record_id: new_role.id,
        record_type: new_role.class.name,
        before_main: before_main,
        after_main: after_main,
        before_associated: {},
        after_associated: {},
        action_name: "create",
        controller_name: "roles",
        configs: [ { only: [], except: [], on: [ :create ], associated: {} } ]
      )
    end

    audit = Core::AuditLog.recent.first
    assert_equal "create", audit.action
    changes = audit.audited_changes.with_indifferent_access
    assert changes["main"]["changes"].present?
  end

  test "audits deleted associated records" do
    before_main = {
      id: @role.id,
      type: @role.class.name,
      attributes: { name: "Role", description: "Desc", code: "CODE" },
      timestamp: Time.current.to_f
    }

    after_main = before_main.dup

    before_associated = {
      permissions: [
        {
          id: 1,
          type: "Core::Permission",
          attributes: { code: "orders.read", resource: "orders", action: "read" }
        }
      ]
    }

    after_associated = {
      permissions: []
    }

    assert_difference("Core::AuditLog.count", 1) do
      Core::AuditLoggerJob.perform_now(
        record_id: @role.id,
        record_type: @role.class.name,
        before_main: before_main,
        after_main: after_main,
        before_associated: before_associated,
        after_associated: after_associated,
        action_name: "update",
        controller_name: "roles",
        configs: [ { only: [], except: [], on: [ :update ], associated: { permissions: {} } } ]
      )
    end

    audit = Core::AuditLog.recent.first
    changes = audit.audited_changes.with_indifferent_access
    assert changes["associated"].present?, "Associated changes should be present"
    deleted = changes["associated"]["permissions"].find { |entry| entry["action"] == "deleted" }
    assert deleted.present?, "Deleted associated record should be tracked"
  end

  test "logs ip_address and user_agent from request" do
    assert_difference("Core::AuditLog.count", 1) do
      Core::AuditLoggerJob.perform_now(
        auditable_type: @role.class.name,
        auditable_id: @role.id,
        action: "updated",
        audited_changes: {},
        metadata: {},
        ip_address: "192.168.1.1",
        user_agent: "Custom Browser/1.0"
      )
    end

    audit = Core::AuditLog.recent.first
    assert_equal "192.168.1.1", audit.ip_address
    assert_equal "Custom Browser/1.0", audit.user_agent
  end
end
