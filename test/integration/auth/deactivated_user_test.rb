require "test_helper"

class DeactivatedUserTest < ActionDispatch::IntegrationTest
  setup do
    @user = core_users(:core_admin)
    @user.update!(deactivated_at: Time.current, deactivated_reason: "policy")
  end

  teardown do
    @user&.update!(deactivated_at: nil, deactivated_reason: nil)
  end

  test "deactivated user cannot login" do
    post auth_login_url, params: { identifier: @user.email, password: "password123" }, as: :json
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "invalid_credentials", body["code"]
  end

  test "deactivated user token refresh returns account_deactivated" do
    @user.update!(deactivated_at: nil, deactivated_reason: nil)
    refresh = Core::RefreshToken.generate(@user, ActionDispatch::Request.new({}))
    @user.update!(deactivated_at: Time.current, deactivated_reason: "policy")

    post auth_refresh_url, params: { refresh_token: refresh.raw_token }, as: :json
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "account_deactivated", body["code"]
  end

  test "deactivated user access token is still valid until expiry" do
    payload = Core::TokenService.access_token_payload(@user)
    token = Core::TokenService.issue(payload)

    get auth_me_url, headers: { "Authorization" => "Bearer #{token}" }, as: :json
    assert_response :success
  end
end
