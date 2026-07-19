# frozen_string_literal: true

require "test_helper"

class Core::Audit::RecordTest < ActiveSupport::TestCase
  test "records a payload-safe audit in the caller transaction" do
    organization = organizations_organizations(:one)
    actor = core_users(:super_admin)

    assert_difference("Core::AuditLog.count", 1) do
      Core::Audit::Record.call(
        audit_key: "event.publish:command-1",
        action: "event.publish",
        auditable_type: organization.class.polymorphic_name,
        auditable_id: organization.id,
        actor_type: actor.class.polymorphic_name,
        actor_id: actor.id,
        audited_changes: { status: { old: "draft", new: "published" } },
        metadata: { command_id: "command-1" },
        request_uuid: "request-1",
        ip_address: "127.0.0.1",
        user_agent: "test"
      )
    end
  end

  test "rolls audit back with the business transaction" do
    organization = organizations_organizations(:one)

    assert_no_difference("Core::AuditLog.count") do
      ApplicationRecord.transaction do
        Core::Audit::Record.call(
          audit_key: "event.publish:rollback",
          action: "event.publish",
          auditable_type: organization.class.polymorphic_name,
          auditable_id: organization.id
        )
        raise ActiveRecord::Rollback
      end
    end
  end

  test "returns the same audit for an identical replay" do
    attributes = {
      audit_key: "ticket.issue:ticket-1",
      action: "ticket.issue",
      auditable_type: "Ticketing::Ticket",
      auditable_id: SecureRandom.uuid,
      audited_changes: { status: { old: "pending", new: "active" } }
    }

    assert_difference("Core::AuditLog.count", 1) do
      first = Core::Audit::Record.call(**attributes)
      second = Core::Audit::Record.call(**attributes.deep_dup)

      assert first.success?
      assert second.success?
      assert_equal first.value.id, second.value.id
    end
  end

  test "rejects reuse of an audit key for a different payload" do
    base = {
      audit_key: "payment.accept:payment-1",
      action: "payment.accept",
      auditable_type: "Orders::Payment",
      auditable_id: SecureRandom.uuid
    }

    Core::Audit::Record.call(**base, metadata: { provider_status: "settled" })

    assert_raises(Core::Audit::Record::ReplayConflict) do
      Core::Audit::Record.call(**base, metadata: { provider_status: "failed" })
    end
  end

  test "rejects credential and attendee secrets recursively" do
    organization = organizations_organizations(:one)

    assert_raises(Core::Audit::Record::SensitivePayload) do
      Core::Audit::Record.call(
        audit_key: "ticket.issue:secret-test",
        action: "ticket.issue",
        auditable_type: organization.class.polymorphic_name,
        auditable_id: organization.id,
        metadata: { delivery: { qr_token: "must-not-be-audited" } }
      )
    end
  end
end
