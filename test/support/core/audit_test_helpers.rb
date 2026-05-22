module Core
  module AuditTestHelpers
    private

    def assert_audit_logged(action:, auditable: nil, actor: nil)
      query = Core::AuditLog.all
      query = query.for_action(action)
      query = query.for_auditable(auditable) if auditable
      query = query.by_actor(actor) if actor

      assert query.exists?, "Expected audit log for action '#{action}'#{": #{auditable.class.name}##{auditable.id}" if auditable}"
    end

    def assert_audit_not_logged(action:, auditable: nil)
      query = Core::AuditLog.all
      query = query.for_action(action)
      query = query.for_auditable(auditable) if auditable

      assert_not query.exists?, "Unexpected audit log for action '#{action}'"
    end

    def assert_audit_log_count(action:, auditable:, expected: 1)
      actual = Core::AuditLog.for_action(action).for_auditable(auditable).count
      assert_equal expected, actual, "Expected #{expected} audit log(s) for '#{action}', got #{actual}"
    end
  end
end
