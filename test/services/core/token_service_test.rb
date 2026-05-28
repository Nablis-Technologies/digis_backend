require "test_helper"

class CoreTokenServiceTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  test "issues and decodes access tokens" do
    user = core_users(:attendee)
    token = Core::TokenService.issue(Core::TokenService.access_token_payload(user))

    payload = Core::TokenService.decode(token)

    assert_equal user.id, payload["user_id"]
    assert_equal "access", payload["type"]
    assert_equal user.active_role_codes, payload["roles"]
  end

  test "raises an authentication error when decoding an expired token" do
    user = core_users(:attendee)

    travel_to Time.current do
      token = Core::TokenService.issue(Core::TokenService.access_token_payload(user), expires_in: 1.second)
      travel 2.seconds

      error = assert_raises(Core::AuthenticationError) do
        Core::TokenService.decode(token)
      end

      assert_equal "token_expired", error.code
    end
  end
end
