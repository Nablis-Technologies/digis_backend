require "test_helper"

class CoreAuthTest < ActionDispatch::IntegrationTest
  test "signup creates a user and assigns the default role" do
    assert_difference("Core::User.count", 1) do
      post "/auth/signup",
           params: {
             user: {
               phone: "251911123456",
               password: "password123",
               password_confirmation: "password123"
             }
           },
           as: :json
    end

    assert_response :created

    payload = JSON.parse(response.body)
    created_user = Core::User.find(payload.dig("data", "user", "id"))

    assert_equal true, payload["success"]
    assert created_user.has_role?("USER")
  end

  test "login with phone returns access and refresh tokens" do
    post "/auth/login",
         params: {
           identifier: core_users(:attendee).phone,
           password: "password123",
           device_id: "web-browser"
         },
         as: :json

    assert_response :success

    payload = JSON.parse(response.body)

    assert payload.dig("data", "access_token").present?
    assert payload.dig("data", "refresh_token").present?
    assert_equal core_users(:attendee).id, payload.dig("data", "user", "id")
    assert_kind_of Array, payload.dig("data", "user", "permissions")
    assert_kind_of Array, payload.dig("data", "user", "roles")
  end

  test "me returns the authenticated user" do
    user = core_users(:attendee)
    token = Core::TokenService.issue(Core::TokenService.access_token_payload(user))

    get "/auth/me", headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success

    payload = JSON.parse(response.body)
    assert_equal user.id, payload.dig("data", "user", "id")
  end

  test "refresh returns a new access token when the refresh token is valid" do
    old_refresh_token = "attendee-refresh-token-secure-value"

    post "/auth/refresh",
         params: {
           refresh_token: old_refresh_token,
           device_id: "web-browser"
         },
         as: :json

    assert_response :success

    payload = JSON.parse(response.body)
    assert payload.dig("data", "access_token").present?, "Should return new access token"
    assert payload.dig("data", "refresh_token").present?, "Should return new refresh token"
    assert_not_equal old_refresh_token, payload.dig("data", "refresh_token"), "Should be a different token"

    # Verify old token is revoked
    old_record = Core::RefreshToken.find_by(token_fingerprint: Digest::SHA256.hexdigest(old_refresh_token))
    assert old_record.revoked?, "Old token should be revoked"
  end

  test "logout revokes the supplied refresh token" do
    user = core_users(:attendee)
    token = Core::TokenService.issue(Core::TokenService.access_token_payload(user))

    post "/auth/logout",
         params: { refresh_token: "attendee-refresh-token-secure-value" },
         headers: { "Authorization" => "Bearer #{token}" },
         as: :json

    assert_response :success

    # Verify token is revoked (not destroyed)
    revoked_record = Core::RefreshToken.find_by(token_fingerprint: Digest::SHA256.hexdigest("attendee-refresh-token-secure-value"))
    assert revoked_record.revoked?, "Token should be revoked"
  end
end
