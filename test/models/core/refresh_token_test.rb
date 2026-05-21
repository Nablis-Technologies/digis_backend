require "test_helper"

class CoreRefreshTokenTest < ActiveSupport::TestCase
  test "expired? returns false when expires_at is nil" do
    token = Core::RefreshToken.new(expires_at: nil)

    assert_equal false, token.expired?
  end

  test "expired? returns true when expires_at is in the past" do
    token = Core::RefreshToken.new(expires_at: 1.minute.ago)

    assert_equal true, token.expired?
  end

  test "generates raw token, fingerprint, and BCrypt hash on creation" do
    user = core_users(:attendee)
    request = ActionDispatch::TestRequest.create
    request.params[:device_id] = "test-device"

    token = Core::RefreshToken.generate(user, request)

    assert token.raw_token.present?
    assert token.token_fingerprint.present?
    assert token.token_hash.present?
    assert_equal Digest::SHA256.hexdigest(token.raw_token), token.token_fingerprint
    assert token.valid_token?(token.raw_token)
  end

  test "valid_token? returns false for wrong token" do
    token = core_refresh_tokens(:attendee_web_token)

    assert_not token.valid_token?("wrong-token-value")
  end

  test "find_valid returns token for correct raw token" do
    raw_token = "attendee-refresh-token-secure-value"
    found = Core::RefreshToken.find_valid(raw_token)

    assert found.present?
    assert_equal core_refresh_tokens(:attendee_web_token).id, found.id
  end

  test "find_valid returns nil for wrong token" do
    found = Core::RefreshToken.find_valid("wrong-token-value")

    assert_nil found
  end

  test "revoke! sets revoked flag and timestamp" do
    token = core_refresh_tokens(:attendee_web_token)

    token.revoke!

    assert token.revoked?
    assert token.revoked_at.present?
  end

  test "active scope excludes revoked tokens" do
    token = core_refresh_tokens(:attendee_web_token)
    token.revoke!

    assert_not Core::RefreshToken.active.exists?(token.id)
  end
end
