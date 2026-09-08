require "test_helper"

class CoreAuthTest < ActionDispatch::IntegrationTest
  test "signup creates a user and assigns the default role" do
    assert_difference("Core::User.count", 1) do
      post "/auth/signup",
           params: {
             user: {
               phone: "+251911123456",
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
    jti = core_refresh_tokens(:attendee_web_token).jti
    token = Core::TokenService.issue(Core::TokenService.access_token_payload(user, jti: jti))

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

  test "refresh returns auth error when refresh token is missing" do
    post "/auth/refresh",
         params: { device_id: "web-browser" },
         as: :json

    assert_response :unauthorized

    payload = JSON.parse(response.body)
    assert_equal false, payload["success"]
    assert payload["error"].present?
  end

  test "signup rejects a weak password and malformed phone" do
    post "/auth/signup",
         params: {
           user: {
             phone: "12345",
             password: "short",
             password_confirmation: "different"
           }
         },
         as: :json

    assert_response :unprocessable_entity
    payload = response.parsed_body
    assert_equal "signup_failed", payload.fetch("code")
    assert payload.fetch("errors").any? { |error| error.include?("password") || error.include?("phone") }
  end

  test "signup requires a password while shadow users remain model-valid" do
    post "/auth/signup", params: { user: { phone: "+251911123460" } }, as: :json

    assert_response :unprocessable_entity
    assert_equal "signup_failed", response.parsed_body.fetch("code")
    assert_includes response.parsed_body.fetch("errors"), "Password is required"
  end

  test "login is throttled without revealing identifier details" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)

    10.times do
      post "/auth/login",
           params: { identifier: "missing@example.com", password: "wrong" },
           as: :json
      assert_response :unauthorized
    end

    post "/auth/login",
         params: { identifier: "missing@example.com", password: "wrong" },
         as: :json

    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body.fetch("code")
    assert_equal "Too many authentication attempts. Please try again later",
      response.parsed_body.fetch("error")
  end

  test "logout revokes the supplied refresh token" do
    user = core_users(:attendee)
    jti = core_refresh_tokens(:attendee_web_token).jti
    token = Core::TokenService.issue(Core::TokenService.access_token_payload(user, jti: jti))

    post "/auth/logout",
         params: { refresh_token: "attendee-refresh-token-secure-value" },
         headers: { "Authorization" => "Bearer #{token}" },
         as: :json

    assert_response :success

    # Verify token is revoked (not destroyed)
    revoked_record = Core::RefreshToken.find_by(token_fingerprint: Digest::SHA256.hexdigest("attendee-refresh-token-secure-value"))
    assert revoked_record.revoked?, "Token should be revoked"

    # Verify the access token is now invalid (JTI revoked)
    get "/auth/me", headers: { "Authorization" => "Bearer #{token}" }, as: :json
    assert_response :unauthorized, "Access token should be invalid after logout"
  end
end
