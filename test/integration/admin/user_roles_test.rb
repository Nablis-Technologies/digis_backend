require "test_helper"

class AdminUserRolesTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test controller: Admin::UserRolesController,
                model: Core::UserRole,
                policy_class: Admin::UserRolePolicy,
                fixture_keys: %i[super_admin core_admin support attendee],
                parent_fixture: :super_admin,
                path: -> { "/admin/users/#{core_users(:super_admin).id}/roles" },
                resource_param: :role_id,
                except: %i[show update],
                create_params: -> {
                  role = core_roles(:user)
                  { user_role: { role_id: role.id } }
                },
                check_attributes: {
                  index: %w[id]
                },
                index: {
                  pagination: { per_page: 2 },
                  ordering: { order_by: "created_at", direction: "desc" }
                }

  test "create assigns role to correct user" do
    target = core_users(:attendee)
    role = core_roles(:support)
    headers = token_headers_for(core_users(:super_admin))
    post "/admin/users/#{target.id}/roles", params: { user_role: { role_id: role.id } }, headers: headers, as: :json
    assert_response :success
    target.clear_permission_cache!
    assert target.reload.has_role?("SUPPORT")
  end

  test "core_admin can assign only USER and SUPPORT roles" do
    target = core_users(:super_admin)
    headers = token_headers_for(core_users(:core_admin))

    post "/admin/users/#{target.id}/roles", params: { user_role: { role_id: core_roles(:user).id } }, headers: headers, as: :json
    assert_response :success

    post "/admin/users/#{target.id}/roles", params: { user_role: { role_id: core_roles(:support).id } }, headers: headers, as: :json
    assert_response :success
  end

  test "core_admin cannot assign CORE_ADMIN role" do
    target = core_users(:support)
    headers = token_headers_for(core_users(:core_admin))
    post "/admin/users/#{target.id}/roles", params: { user_role: { role_id: core_roles(:core_admin).id } }, headers: headers, as: :json
    assert_response :forbidden
  end

  test "destroy removes role from user" do
    target = core_users(:support)
    user_role = target.user_roles.joins(:role).find_by(core_roles: { code: "SUPPORT" })
    headers = token_headers_for(core_users(:super_admin))
    delete "/admin/users/#{target.id}/roles/#{user_role.role_id}", headers: headers, as: :json
    assert_response :success
    assert_not target.reload.has_role?("SUPPORT")
  end

  test "create stamps assigned_by" do
    target = core_users(:attendee)
    role = core_roles(:support)
    actor = core_users(:super_admin)
    headers = token_headers_for(actor)
    post "/admin/users/#{target.id}/roles", params: { user_role: { role_id: role.id } }, headers: headers, as: :json
    assert_response :success
    assignment = Core::UserRole.order(:created_at).last
    assert_equal actor.id, assignment.assigned_by_id
  end

  test "create logs an audit with assigned_by" do
    target = core_users(:attendee)
    role = core_roles(:support)
    headers = token_headers_for(core_users(:super_admin))
    perform_enqueued_jobs do
      post "/admin/users/#{target.id}/roles", params: { user_role: { role_id: role.id } }, headers: headers, as: :json
    end
    assert_response :success
    assert_audit_logged(action: "create", actor: core_users(:super_admin))
  end
end
