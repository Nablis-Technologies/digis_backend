# frozen_string_literal: true

require "test_helper"

class Core::Audit::BuildControllerPayloadTest < ActiveSupport::TestCase
  def snapshot(record, **overrides)
    {
      id: record.id,
      type: record.class.polymorphic_name,
      attributes: record.attributes.merge(overrides.stringify_keys),
      timestamp: Time.current.to_f
    }
  end

  test "automatically produces the filtered update diff" do
    role = core_roles(:core_admin)
    actor = core_users(:super_admin)

    result = Core::Audit::BuildControllerPayload.call(
      record_id: role.id,
      record_type: role.class.polymorphic_name,
      before_main: snapshot(role, name: "Old", description: "Hidden old"),
      after_main: snapshot(role, name: "New", description: "Hidden new"),
      before_associated: {},
      after_associated: {},
      action_name: "update",
      controller_name: "admin/roles",
      configs: [ { only: [ :name ], except: [], associated: {}, action: nil } ],
      actor_id: actor.id,
      actor_type: actor.class.polymorphic_name,
      request_uuid: "request-automatic-diff",
      ip_address: "127.0.0.1",
      user_agent: "test"
    )

    assert result.success?
    changes = result.value.fetch(:audited_changes).with_indifferent_access.dig(:main, :changes)
    assert_equal({ "old" => "Old", "new" => "New" }, changes.fetch(:name).stringify_keys)
    assert_not changes.key?(:description)
  end

  test "returns nil when nothing changed" do
    role = core_roles(:core_admin)
    same = snapshot(role)

    result = Core::Audit::BuildControllerPayload.call(
      record_id: role.id,
      record_type: role.class.polymorphic_name,
      before_main: same,
      after_main: same,
      before_associated: {},
      after_associated: {},
      action_name: "update",
      controller_name: "admin/roles",
      configs: [ { only: [], except: [], associated: {}, action: nil } ],
      actor_id: nil,
      actor_type: nil,
      request_uuid: "no-change",
      ip_address: nil,
      user_agent: nil
    )

    assert_nil result.value
  end

  test "filters with except" do
    role = core_roles(:core_admin)
    result = Core::Audit::BuildControllerPayload.call(
      record_id: role.id,
      record_type: role.class.polymorphic_name,
      before_main: snapshot(role, name: "Old", description: "Old Desc"),
      after_main: snapshot(role, name: "New", description: "New Desc"),
      before_associated: {},
      after_associated: {},
      action_name: "update",
      controller_name: "admin/roles",
      configs: [ { only: [], except: [ :description ], associated: {}, action: nil } ],
      actor_id: nil, actor_type: nil, request_uuid: "except", ip_address: nil, user_agent: nil
    )

    changes = result.value.fetch(:audited_changes).with_indifferent_access.dig(:main, :changes)
    assert_includes changes.keys.map(&:to_s), "name"
    assert_not_includes changes.keys.map(&:to_s), "description"
  end

  test "uses a custom action label from config" do
    role = core_roles(:core_admin)
    result = Core::Audit::BuildControllerPayload.call(
      record_id: role.id,
      record_type: role.class.polymorphic_name,
      before_main: snapshot(role, name: "Old"),
      after_main: snapshot(role, name: "New"),
      before_associated: {},
      after_associated: {},
      action_name: "update",
      controller_name: "admin/roles",
      configs: [ { only: [], except: [], associated: {}, action: { update: "published" } } ],
      actor_id: nil, actor_type: nil, request_uuid: "label", ip_address: nil, user_agent: nil
    )

    assert_equal "published", result.value[:action]
  end

  test "tracks deleted associated records" do
    role = core_roles(:core_admin)
    before_associated = {
      permissions: [ { id: 1, type: "Core::Permission",
                       attributes: { code: "orders.read", resource: "orders", action: "read" } } ]
    }

    result = Core::Audit::BuildControllerPayload.call(
      record_id: role.id,
      record_type: role.class.polymorphic_name,
      before_main: snapshot(role),
      after_main: snapshot(role),
      before_associated: before_associated,
      after_associated: { permissions: [] },
      action_name: "update",
      controller_name: "admin/roles",
      configs: [ { only: [], except: [], associated: { permissions: {} }, action: nil } ],
      actor_id: nil, actor_type: nil, request_uuid: "assoc", ip_address: nil, user_agent: nil
    )

    associated = result.value.fetch(:audited_changes).with_indifferent_access[:associated]
    deleted = associated["permissions"].find { |entry| entry["action"] == "deleted" }
    assert deleted.present?, "Deleted associated record should be tracked"
  end

  test "captures actor, request uuid, ip, and user agent" do
    role = core_roles(:core_admin)
    actor = core_users(:super_admin)
    result = Core::Audit::BuildControllerPayload.call(
      record_id: role.id,
      record_type: role.class.polymorphic_name,
      before_main: snapshot(role, name: "Old"),
      after_main: snapshot(role, name: "New"),
      before_associated: {},
      after_associated: {},
      action_name: "update",
      controller_name: "admin/roles",
      configs: [ { only: [], except: [], associated: {}, action: nil } ],
      actor_id: actor.id,
      actor_type: actor.class.polymorphic_name,
      request_uuid: "req-actor",
      ip_address: "10.0.0.1",
      user_agent: "Agent/1.0"
    )

    value = result.value
    assert_equal actor.id, value[:actor_id]
    assert_equal "req-actor", value[:request_uuid]
    assert_equal "10.0.0.1", value[:ip_address]
    assert_equal "Agent/1.0", value[:user_agent]
  end
end
