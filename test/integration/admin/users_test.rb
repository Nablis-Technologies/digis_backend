require "test_helper"

class AdminUsersTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test model: Core::User,
                policy_class: Admin::UserPolicy,
                fixture_keys: %i[super_admin core_admin support attendee],
                path: "/admin/users",
                except: %i[destroy],
                create_params: -> { { user: { email: "new_#{SecureRandom.hex(8)}@example.com", phone: "+251#{SecureRandom.hex(8)}", password: "password123" } } },
                update_params: ->(record) { { user: { email: "updated_#{SecureRandom.hex(4)}@example.com" } } },
                check_attributes: {
                  index: %w[id email phone verified_at],
                  show: %w[id email phone verified_at deactivated_at]
                },
                index: {
                  pagination: { per_page: 2 },
                  ordering: { order_by: "email", direction: "asc" }
                }

  test "deactivate user (super_admin)" do
    user = core_users(:support)
    headers = token_headers_for(core_users(:super_admin))
    post "/admin/users/#{user.id}/deactivate", params: { deactivated_reason: "fraud" }, headers: headers, as: :json
    assert_response :success
    assert user.reload.deactivated?
    assert_equal "fraud", user.deactivated_reason
  end

  test "deactivate user (core_admin)" do
    user = core_users(:support)
    headers = token_headers_for(core_users(:core_admin))
    post "/admin/users/#{user.id}/deactivate", params: { deactivated_reason: "policy" }, headers: headers, as: :json
    assert_response :success
    assert user.reload.deactivated?
  end

  test "deactivate user (support)" do
    user = core_users(:attendee)
    headers = token_headers_for(core_users(:support))
    post "/admin/users/#{user.id}/deactivate", params: { deactivated_reason: "policy" }, headers: headers, as: :json
    assert_response :success
    assert user.reload.deactivated?
  end

  test "deactivate forbidden for attendee" do
    user = core_users(:support)
    headers = token_headers_for(core_users(:attendee))
    post "/admin/users/#{user.id}/deactivate", params: { deactivated_reason: "policy" }, headers: headers, as: :json
    assert_response :forbidden
  end

  test "self deactivation is blocked" do
    user = core_users(:core_admin)
    headers = token_headers_for(user)
    post "/admin/users/#{user.id}/deactivate", params: { deactivated_reason: "policy" }, headers: headers, as: :json
    assert_response :unauthorized
  end

  test "reactivate user (core_admin)" do
    user = core_users(:support)
    user.update!(deactivated_at: Time.current, deactivated_reason: "policy")

    headers = token_headers_for(core_users(:core_admin))
    post "/admin/users/#{user.id}/reactivate", headers: headers, as: :json
    assert_response :success
    assert_not user.reload.deactivated?
  end

  test "reactivate fraud user requires super_admin" do
    user = core_users(:support)
    user.update!(deactivated_at: Time.current, deactivated_reason: "fraud")

    headers = token_headers_for(core_users(:core_admin))
    post "/admin/users/#{user.id}/reactivate", headers: headers, as: :json
    assert_response :forbidden

    headers = token_headers_for(core_users(:super_admin))
    post "/admin/users/#{user.id}/reactivate", headers: headers, as: :json
    assert_response :success
    assert_not user.reload.deactivated?
  end

  test "index with status=all returns all users" do
    core_users(:support).update!(deactivated_at: Time.current, deactivated_reason: "policy")
    headers = token_headers_for(core_users(:super_admin))
    get "/admin/users?status=all", headers: headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    user_ids = data.map { |u| u["id"] }
    assert_includes user_ids, core_users(:support).id
  end

  test "index defaults to active users" do
    deactivated = core_users(:support)
    deactivated.update!(deactivated_at: Time.current, deactivated_reason: "policy")
    headers = token_headers_for(core_users(:super_admin))
    get "/admin/users", headers: headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    user_ids = data.map { |u| u["id"] }
    assert_not_includes user_ids, deactivated.id
  end

  test "index with status=deactivated returns only deactivated users" do
    deactivated = core_users(:support)
    deactivated.update!(deactivated_at: Time.current, deactivated_reason: "test")

    headers = token_headers_for(core_users(:super_admin))
    get "/admin/users?status=deactivated", headers: headers, as: :json
    assert_response :success

    data = JSON.parse(response.body).dig("data")
    user_ids = data.map { |u| u["id"] }

    assert_includes user_ids, deactivated.id
    assert_not_includes user_ids, core_users(:super_admin).id
  end

  test "index composes active filter with policy scope" do
    excluded_user = core_users(:support)

    narrow_scope = Core::User.where(id: core_users(:super_admin).id)
    Admin::UsersController.any_instance.stubs(:policy_scope).returns(narrow_scope)

    headers = token_headers_for(core_users(:super_admin))
    get "/admin/users", headers: headers, as: :json
    assert_response :success

    data = JSON.parse(response.body).dig("data")
    user_ids = data.map { |u| u["id"] }

    assert_equal [ core_users(:super_admin).id ], user_ids
  end

  test "deactivate revokes all tokens" do
    user = core_users(:support)
    token = Core::RefreshToken.generate(user, ActionDispatch::Request.new({}))
    headers = token_headers_for(core_users(:super_admin))
    post "/admin/users/#{user.id}/deactivate", params: { deactivated_reason: "policy" }, headers: headers, as: :json
    assert_response :success
    assert_not token.reload.active?
  end

  test "deactivate logs an audit" do
    user = core_users(:support)
    headers = token_headers_for(core_users(:super_admin))
    perform_enqueued_jobs do
      post "/admin/users/#{user.id}/deactivate", params: { deactivated_reason: "policy" }, headers: headers, as: :json
    end
    assert_response :success
    assert_audit_logged(action: "update", auditable: user, actor: core_users(:super_admin))
  end

  test "reactivate logs an audit" do
    user = core_users(:support)
    user.update!(deactivated_at: Time.current, deactivated_reason: "left")
    headers = token_headers_for(core_users(:super_admin))
    perform_enqueued_jobs do
      post "/admin/users/#{user.id}/reactivate", headers: headers, as: :json
    end
    assert_response :success
    user.reload
    assert_nil user.deactivated_at
    assert_nil user.deactivated_reason
    assert_audit_logged(action: "update", auditable: user, actor: core_users(:super_admin))
  end

  test "show returns 404 with clean message for non-existent record" do
    headers = token_headers_for(core_users(:super_admin))
    get "/admin/users/nonexistent-id", headers: headers, as: :json
    assert_response :not_found

    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_match /user.*not found/i, body["error"]
  end
end
