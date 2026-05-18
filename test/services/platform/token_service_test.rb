require "test_helper"

class PlatformTokenServiceTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  test "issues and decodes access tokens" do
    user = platform_users(:attendee)
    token = Platform::TokenService.issue(Platform::TokenService.access_token_payload(user))

    payload = Platform::TokenService.decode(token)

    assert_equal user.id, payload["user_id"]
    assert_equal "access", payload["type"]
    assert_equal user.active_role_codes, payload["roles"]
  end

  test "raises an authentication error when decoding an expired token" do
    user = platform_users(:attendee)

    travel_to Time.current do
      token = Platform::TokenService.issue(Platform::TokenService.access_token_payload(user), expires_in: 1.second)
      travel 2.seconds

      error = assert_raises(Platform::AuthenticationError) do
        Platform::TokenService.decode(token)
      end

      assert_equal "token_expired", error.code
    end
  end
end
