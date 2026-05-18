require "test_helper"

class PlatformRefreshTokenTest < ActiveSupport::TestCase
  test "expired? returns false when expires_at is nil" do
    token = Platform::RefreshToken.new(expires_at: nil)

    assert_equal false, token.expired?
  end

  test "expired? returns true when expires_at is in the past" do
    token = Platform::RefreshToken.new(expires_at: 1.minute.ago)

    assert_equal true, token.expired?
  end
end