require "test_helper"

class CoreAuthTest < ActionDispatch::IntegrationTest
  include Core::CurrentUserProjectionTestHelpers

  test "signup rejects a phone without verified ownership proof" do
    phone = "+251911123456"

    post "/auth/signup",
         params: {
           user: {
             phone:,
             password: "password123",
             password_confirmation: "password123"
           },
           phone_confirmation: true
         },
         headers: { "Idempotency-Key" => "signup-proof-required" },
         as: :json

    assert_response :unprocessable_entity
    assert_equal "phone_verification_required", response.parsed_body.fetch("code")
    assert_nil Core::User.find_by(phone:)
  end

  test "signup OTP request creates a shadow and returns only challenge metadata" do
    phone = "+251911123461"

    with_phone_verification_sender do |deliveries|
      assert_difference("Core::User.count", 1) do
        post "/auth/signup/request_otp",
             params: { phone: },
             headers: { "Idempotency-Key" => "signup-otp-new-phone" },
             as: :json
      end

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal %w[challenge_id expires_at status], data.keys.sort
      assert_equal "pending", data.fetch("status")
      assert_equal 1, deliveries.length
      assert_equal phone, deliveries.first.fetch(:phone)
      assert_equal data.fetch("challenge_id"), deliveries.first.fetch(:challenge_id)
      assert_not_includes response.body, deliveries.first.fetch(:code)
      assert_not_includes response.body, phone

      post "/auth/signup/request_otp",
           params: { phone: },
           headers: { "Idempotency-Key" => "signup-otp-new-phone" },
           as: :json

      assert_response :created
      assert_equal data.fetch("challenge_id"), response.parsed_body.dig("data", "challenge_id")
      assert_equal 1, deliveries.length
      assert_equal 1, Core::User.where(phone:).count

      challenge = Core::PhoneVerificationChallenge.includes(:user).find(data.fetch("challenge_id"))
      assert_equal "account_signup", challenge.purpose
      assert_nil challenge.user.password_digest
      assert_nil challenge.user.verified_at
      assert_empty challenge.user.roles
    end
  end

  test "signup OTP request reuses an existing shadow phone identity" do
    shadow = Core::User.create!(phone: "+251911123462")

    with_phone_verification_sender do |deliveries|
      assert_no_difference("Core::User.count") do
        post "/auth/signup/request_otp",
             params: { phone: shadow.phone },
             headers: { "Idempotency-Key" => "signup-otp-existing-shadow" },
             as: :json
      end

      assert_response :created
      challenge = Core::PhoneVerificationChallenge.find(response.parsed_body.dig("data", "challenge_id"))
      assert_equal shadow.id, challenge.user_id
      assert_equal 1, deliveries.length
    end
  end

  test "signup OTP request has the same response shape for an existing account" do
    account = Core::User.create!(
      phone: "+251911123463",
      password: "password123",
      verified_at: Time.current
    )

    with_phone_verification_sender do |deliveries|
      post "/auth/signup/request_otp",
           params: { phone: account.phone },
           headers: { "Idempotency-Key" => "signup-otp-existing-account" },
           as: :json

      assert_response :created
      assert_equal %w[challenge_id expires_at status], response.parsed_body.dig("data").keys.sort
      challenge = Core::PhoneVerificationChallenge.find(response.parsed_body.dig("data", "challenge_id"))
      assert_equal account.id, challenge.user_id
      assert_equal 1, deliveries.length
    end
  end

  test "signup OTP request requires an idempotency key" do
    post "/auth/signup/request_otp", params: { phone: "+251911123464" }, as: :json

    assert_response :bad_request
    assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    assert_nil Core::User.find_by(phone: "+251911123464")
  end

  test "signup requires an idempotency key" do
    post "/auth/signup",
         params: {
           user: {
             phone: "+251911123464",
             password: "password123",
             password_confirmation: "password123"
           },
           verification_token: "any-token"
         },
         as: :json

    assert_response :bad_request
    assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    assert_nil Core::User.find_by(phone: "+251911123464")
  end

  test "signup OTP request limits successful sends per phone and IP" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)
    phone = "+251911123472"

    with_phone_verification_sender do |deliveries|
      requests = lambda do
        10.times do |index|
          post "/auth/signup/request_otp",
               params: { phone: },
               headers: { "Idempotency-Key" => "signup-otp-rate-limit-#{index}" },
               as: :json
          assert_response :created
        end

        post "/auth/signup/request_otp",
             params: { phone: },
             headers: { "Idempotency-Key" => "signup-otp-rate-limit-11" },
             as: :json

        assert_response :too_many_requests
        assert_equal "rate_limited", response.parsed_body.fetch("code")
        assert_equal 10, deliveries.length
      end
      defined?(Prosopite) ? Prosopite.pause(&requests) : requests.call
    end
  end

  test "signup OTP request throttles the canonical destination despite caller identifiers and IP changes" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)
    phone_forms = [ "+251911123473", "0911123473" ]

    with_phone_verification_sender do |deliveries|
      requests = lambda do
        10.times do |index|
          post "/auth/signup/request_otp",
               params: { phone: phone_forms[index % phone_forms.length], identifier: "caller-#{index}" },
               headers: {
                 "Idempotency-Key" => "signup-phone-throttle-#{index}",
                 "REMOTE_ADDR" => "198.51.100.#{index + 1}"
               },
               as: :json
          assert_response :created
        end

        post "/auth/signup/request_otp",
             params: { phone: phone_forms.first, identifier: "caller-eleven" },
             headers: {
               "Idempotency-Key" => "signup-phone-throttle-11",
               "REMOTE_ADDR" => "198.51.100.11"
             },
             as: :json

        assert_response :too_many_requests
        assert_equal "rate_limited", response.parsed_body.fetch("code")
        assert_equal 10, deliveries.length
      end
      defined?(Prosopite) ? Prosopite.pause(&requests) : requests.call
    end
  end

  test "signup failure throttles by canonical phone despite caller identifiers and IP changes" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)
    phone_forms = [ "+251911123475", "0911123475" ]

    requests = lambda do
      10.times do |index|
        phone = phone_forms[index % phone_forms.length]
        ip_address = "198.51.100.#{index + 21}"
        post "/auth/signup",
             params: {
               user: { phone:, password: "password123", password_confirmation: "password123" },
               identifier: "caller-#{index}",
               verification_token: "invalid-proof-#{index}"
             },
             headers: {
               "Idempotency-Key" => "signup-failure-throttle-#{index}",
               "REMOTE_ADDR" => ip_address
             },
             as: :json

        assert_response :forbidden
        assert_equal "verification_invalid", response.parsed_body.fetch("code")
        ip_digest = Core::KeyedDigest.digest(namespace: "core/auth-throttle/ip", value: ip_address)
        assert_equal 1, cache.read("core-auth-throttle:#{ip_digest}")
      end

      post "/auth/signup",
           params: {
             user: { phone: phone_forms.first, password: "password123", password_confirmation: "password123" },
             identifier: "caller-eleven",
             verification_token: "invalid-proof-eleven"
           },
           headers: {
             "Idempotency-Key" => "signup-failure-throttle-11",
             "REMOTE_ADDR" => "198.51.100.31"
           },
           as: :json

      assert_response :too_many_requests
      assert_equal "rate_limited", response.parsed_body.fetch("code")
    end
    defined?(Prosopite) ? Prosopite.pause(&requests) : requests.call
  end

  test "signup authenticates only replayed requests after upgrading a new shadow" do
    phone = "+251911123476"

    with_phone_verification_sender do |deliveries|
      token = request_signup_verification(phone:, key: "signup-single-password-check", deliveries:)
      Core::User.any_instance.expects(:authenticate).never

      post "/auth/signup",
           params: {
             user: {
               phone:,
               first_name: "Aster",
               last_name: "Bekele",
               password: "password123",
               password_confirmation: "password123"
             },
             verification_token: token
           },
           headers: { "Idempotency-Key" => "signup-single-password-check-complete" },
           as: :json

      assert_response :created
      assert response.parsed_body.dig("data", "access_token").present?
    end
  end

  test "signup rechecks the current password when the same key wins a concurrent completion race" do
    phone = "+251911123477"
    signup_attributes = {
      phone:,
      first_name: "Aster",
      last_name: "Bekele",
      password: "original-password",
      password_confirmation: "original-password"
    }

    with_phone_verification_sender do |deliveries|
      token = request_signup_verification(phone:, key: "signup-race-replay", deliveries:)
      post "/auth/signup",
           params: { user: signup_attributes, verification_token: token },
           headers: { "Idempotency-Key" => "signup-race-replay-complete" },
           as: :json

      assert_response :created
      user = Core::User.find_by!(phone:)
      user.update!(password: "replacement-password", password_confirmation: "replacement-password")
      audit_key = "core-auth-signup-#{Core::IdempotencyKey.new("signup-race-replay-complete").digest}"
      audit = Core::AuditLog.find_by!(audit_key:)
      Core::AuditLog.expects(:find_by).with(audit_key:).twice.returns(nil, audit)

      post "/auth/signup",
           params: { user: signup_attributes, verification_token: token },
           headers: { "Idempotency-Key" => "signup-race-replay-complete" },
           as: :json

      assert_response :unauthorized
      assert_equal "invalid_credentials", response.parsed_body.fetch("code")
      assert user.reload.authenticate("replacement-password")
    end
  end

  test "signup upgrades a phone-verified shadow and returns auth tokens" do
    phone = "+251911123465"

    with_phone_verification_sender do |deliveries|
      token = request_signup_verification(phone:, key: "signup-shadow-upgrade", deliveries:)
      shadow = Core::User.find_by!(phone:)
      assert_nil shadow.password_digest
      assert_nil shadow.verified_at

      assert_no_difference("Core::User.count") do
        post "/auth/signup",
             params: {
               user: {
                 phone:,
                 email: "signup-shadow@example.com",
                 first_name: "Aster",
                 last_name: "Bekele",
                 password: "password123",
                 password_confirmation: "password123"
               },
               verification_token: token
             },
             headers: { "Idempotency-Key" => "signup-shadow-upgrade" },
             as: :json
      end

      assert_response :created
      payload = response.parsed_body
      upgraded = Core::User.find(payload.dig("data", "user", "id"))
      assert_equal shadow.id, upgraded.id
      assert upgraded.verified_at.present?
      assert upgraded.authenticate("password123")
      assert upgraded.has_role?("USER")
      assert payload.dig("data", "access_token").present?
      assert payload.dig("data", "refresh_token").present?
      assert_equal 1, deliveries.length

      post "/auth/signup",
           params: {
             user: {
               phone:,
               email: "signup-shadow@example.com",
                 first_name: "Aster",
                 last_name: "Bekele",
               password: "password123",
               password_confirmation: "password123"
             },
             verification_token: token
           },
           headers: { "Idempotency-Key" => "signup-shadow-upgrade" },
           as: :json

      assert_response :created
      assert_equal upgraded.id, response.parsed_body.dig("data", "user", "id")
      replayed_access_token = response.parsed_body.dig("data", "access_token")
      assert replayed_access_token.present?
      assert response.parsed_body.dig("data", "refresh_token").present?
      assert_equal 1, Core::AuditLog.where(
        action: "core.user.signup_completed", auditable_id: upgraded.id
      ).count

      get "/user", headers: { "Authorization" => "Bearer #{replayed_access_token}" }, as: :json

      assert_response :success
      assert_equal upgraded.id, response.parsed_body.dig("data", "id")

      post "/auth/signup",
           params: {
             user: {
               phone:,
               email: "different@example.com",
                 first_name: "Aster",
                 last_name: "Bekele",
               password: "different123",
               password_confirmation: "different123"
             },
             verification_token: token
           },
           headers: { "Idempotency-Key" => "signup-shadow-upgrade" },
           as: :json

      assert_response :conflict
      assert_equal "idempotency_conflict", response.parsed_body.fetch("code")
      assert upgraded.reload.authenticate("password123")
    end
  end

  test "signup persists profile names and replays without creating another profile" do
    phone = "+251911123476"
    key = "signup-profile-names"

    with_phone_verification_sender do |deliveries|
      verification_token = request_signup_verification(phone:, key:, deliveries:)
      signup_params = {
        user: {
          phone:,
          first_name: "አስቴር",
          last_name: "በቀለ",
          password: "password123",
          password_confirmation: "password123"
        },
        verification_token: verification_token
      }

      assert_difference("Core::UserProfile.count", 1) do
        with_strict_current_user_projection do
          post "/auth/signup",
               params: signup_params,
               headers: { "Idempotency-Key" => key },
               as: :json
        end
      end

      assert_response :created
      assert_equal(
        {
          "first_name" => "አስቴር",
          "last_name" => "በቀለ",
          "full_name" => "አስቴር በቀለ",
          "avatar_url" => nil
        },
        response.parsed_body.dig("data", "user", "profile")
      )
      user_id = response.parsed_body.dig("data", "user", "id")
      profile = Core::UserProfile.find_by(user_id: user_id)
      assert_not_nil profile
      assert_equal "አስቴር", profile.first_name
      assert_equal "በቀለ", profile.last_name

      assert_no_difference("Core::UserProfile.count") do
        with_strict_current_user_projection do
          post "/auth/signup",
               params: signup_params,
               headers: { "Idempotency-Key" => key },
               as: :json
        end
      end

      assert_response :created
      assert_equal profile.id, Core::UserProfile.find_by(user_id: user_id).id

      changed_params = signup_params.deep_dup
      changed_params[:user][:first_name] = "Selam"
      with_strict_current_user_projection do
        post "/auth/signup",
             params: changed_params,
             headers: { "Idempotency-Key" => key },
             as: :json
      end

      assert_response :conflict
      assert_equal "idempotency_conflict", response.parsed_body.fetch("code")
      assert_equal "አስቴር", profile.reload.first_name
      audit = Core::AuditLog.find_by!(action: "core.user.signup_completed", auditable_id: user_id)
      refute_includes audit.audited_changes.to_json, "አስቴር"
      refute_includes audit.audited_changes.to_json, "በቀለ"
      refute_includes audit.metadata.to_json, "አስቴር"
      refute_includes audit.metadata.to_json, "በቀለ"
    end
  end

  test "signup rejects missing profile names without upgrading the shadow user" do
    phone = "+251911123478"

    with_phone_verification_sender do |deliveries|
      token = request_signup_verification(phone:, key: "signup-profile-required", deliveries:)
      post "/auth/signup",
           params: {
             user: {
               phone:,
               password: "password123",
               password_confirmation: "password123"
             },
             verification_token: token
           },
           headers: { "Idempotency-Key" => "signup-profile-required-complete" },
           as: :json

      assert_response :unprocessable_entity
      assert_equal "signup_failed", response.parsed_body.fetch("code")
      errors = response.parsed_body.fetch("errors")
      assert_includes errors.keys, "first_name"
      assert_includes errors.keys, "last_name"
      shadow = Core::User.find_by!(phone:)
      assert_nil shadow.password_digest
      assert_nil shadow.verified_at
      assert_not Core::UserProfile.exists?(user_id: shadow.id)
      assert_empty Core::AuditLog.where(action: "core.user.signup_completed", auditable_id: shadow.id)
    end
  end

  test "signup replay cannot authenticate with a password changed after signup" do
    phone = "+251911123474"
    signup_attributes = {
      phone:,
      first_name: "Aster",
      last_name: "Bekele",
      password: "original-password",
      password_confirmation: "original-password"
    }

    with_phone_verification_sender do |deliveries|
      token = request_signup_verification(phone:, key: "signup-password-rotation", deliveries:)
      post "/auth/signup",
           params: { user: signup_attributes, verification_token: token },
           headers: { "Idempotency-Key" => "signup-password-rotation-complete" },
           as: :json

      assert_response :created
      user = Core::User.find_by!(phone:)
      user.update!(password: "replacement-password", password_confirmation: "replacement-password")

      post "/auth/signup",
           params: { user: signup_attributes, verification_token: token },
           headers: { "Idempotency-Key" => "signup-password-rotation-complete" },
           as: :json

      assert_response :unauthorized
      assert_equal "invalid_credentials", response.parsed_body.fetch("code")
      assert_nil response.parsed_body.dig("data", "access_token")
      assert user.reload.authenticate("replacement-password")
      assert_not user.authenticate("original-password")
    end
  end

  test "signup returns phone_taken after proving a real account's phone" do
    account = Core::User.create!(
      phone: "+251911123466",
      password: "original-password",
      password_confirmation: "original-password",
      verified_at: 1.day.ago
    )

    with_phone_verification_sender do |deliveries|
      token = request_signup_verification(phone: account.phone, key: "signup-real-account", deliveries:)
      original_verified_at = account.verified_at

      post "/auth/signup",
           params: {
             user: {
               phone: account.phone,
               password: "replacement123",
               password_confirmation: "replacement123"
             },
             verification_token: token
           },
           headers: { "Idempotency-Key" => "signup-real-account-complete" },
           as: :json

      assert_response :unprocessable_entity
      assert_equal "phone_taken", response.parsed_body.fetch("code")
      assert account.reload.authenticate("original-password")
      assert_not account.authenticate("replacement123")
      assert_equal original_verified_at, account.verified_at
      assert_equal 1, deliveries.length
    end
  end

  test "signup rejects a proof bound to a different phone" do
    with_phone_verification_sender do |deliveries|
      token = request_signup_verification(phone: "+251911123467", key: "signup-proof-source", deliveries:)

      post "/auth/signup",
           params: {
             user: {
               phone: "+251911123468",
               password: "password123",
               password_confirmation: "password123"
             },
             verification_token: token
           },
           headers: { "Idempotency-Key" => "signup-proof-other-phone" },
           as: :json

      assert_response :forbidden
      assert_equal "verification_invalid", response.parsed_body.fetch("code")
      assert_nil Core::User.find_by(phone: "+251911123468")
    end
  end

  test "signup rejects a proof minted for a different purpose" do
    phone = "+251911123470"
    shadow = Core::User.create!(phone:)

    with_phone_verification_sender do |deliveries|
      challenge = Core::PhoneVerification::Request.call(
        user: shadow,
        phone:,
        purpose: "guest_claim",
        idempotency_key: "signup-wrong-purpose-request"
      ).value
      proof = Core::PhoneVerification::Verify.call(
        challenge:,
        code: deliveries.last.fetch(:code)
      ).value.token

      post "/auth/signup",
           params: {
             user: {
               phone:,
               password: "password123",
               password_confirmation: "password123"
             },
             verification_token: proof
           },
           headers: { "Idempotency-Key" => "signup-wrong-purpose-complete" },
           as: :json

      assert_response :forbidden
      assert_equal "verification_invalid", response.parsed_body.fetch("code")
      assert_nil shadow.reload.password_digest
      assert_nil shadow.verified_at
    end
  end

  test "signup rejects a proof after its challenge expires" do
    phone = "+251911123471"
    shadow = Core::User.create!(phone:)

    with_phone_verification_sender do |deliveries|
      challenge = Core::PhoneVerification::Request.call(
        user: shadow,
        phone:,
        purpose: "account_signup",
        idempotency_key: "signup-expired-proof-request"
      ).value
      proof = Core::PhoneVerification::Verify.call(
        challenge:,
        code: deliveries.last.fetch(:code)
      ).value.token
      challenge.update_column(:expires_at, 1.second.ago)

      post "/auth/signup",
           params: {
             user: {
               phone:,
               password: "password123",
               password_confirmation: "password123"
             },
             verification_token: proof
           },
           headers: { "Idempotency-Key" => "signup-expired-proof-complete" },
           as: :json

      assert_response :forbidden
      assert_equal "verification_invalid", response.parsed_body.fetch("code")
      assert_nil shadow.reload.password_digest
      assert_nil shadow.verified_at
    end
  end

  test "login with phone returns access and refresh tokens" do
    Core::UserProfile.create!(user: core_users(:attendee), first_name: "Aster", last_name: "Bekele")

    with_strict_current_user_projection do
      post "/auth/login",
           params: {
             identifier: core_users(:attendee).phone,
             password: "password123",
             device_id: "web-browser"
           },
           as: :json
    end

    assert_response :success

    payload = JSON.parse(response.body)

    assert payload.dig("data", "access_token").present?
    assert payload.dig("data", "refresh_token").present?
    assert_equal core_users(:attendee).id, payload.dig("data", "user", "id")
    assert_kind_of Array, payload.dig("data", "user", "permissions")
    assert_kind_of Array, payload.dig("data", "user", "roles")
    assert_equal "Aster Bekele", payload.dig("data", "user", "profile", "full_name")
  end

  test "refresh returns a new access token when the refresh token is valid" do
    old_refresh_token = "attendee-refresh-token-secure-value"
    Core::UserProfile.create!(user: core_users(:attendee), first_name: "Aster", last_name: "Bekele")

    with_strict_current_user_projection do
      post "/auth/refresh",
           params: {
             refresh_token: old_refresh_token,
             device_id: "web-browser"
           },
           as: :json
    end

    assert_response :success

    payload = JSON.parse(response.body)
    assert payload.dig("data", "access_token").present?, "Should return new access token"
    assert payload.dig("data", "refresh_token").present?, "Should return new refresh token"
    assert_not_equal old_refresh_token, payload.dig("data", "refresh_token"), "Should be a different token"
    assert_equal "Aster Bekele", payload.dig("data", "user", "profile", "full_name")

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

  test "signup rejects a weak password after verifying the phone" do
    phone = "+251911123469"

    with_phone_verification_sender do |deliveries|
      token = request_signup_verification(phone:, key: "signup-weak-password", deliveries:)
      post "/auth/signup",
           params: {
             user: { phone:, password: "short", password_confirmation: "different" },
             verification_token: token
           },
           headers: { "Idempotency-Key" => "signup-weak-password-complete" },
           as: :json

      assert_response :unprocessable_entity
      assert_equal "signup_failed", response.parsed_body.fetch("code")
      assert response.parsed_body.fetch("errors").any? { |error| error.include?("password") }
      shadow = Core::User.find_by!(phone:)
      assert_nil shadow.password_digest
      assert_nil shadow.verified_at
    end
  end

  test "signup requires a password while shadow users remain model-valid" do
    phone = "+251911123460"

    with_phone_verification_sender do |deliveries|
      token = request_signup_verification(phone:, key: "signup-password-required", deliveries:)
      post "/auth/signup",
           params: { user: { phone: }, verification_token: token },
           headers: { "Idempotency-Key" => "signup-password-required-complete" },
           as: :json

      assert_response :unprocessable_entity
      assert_equal "signup_failed", response.parsed_body.fetch("code")
      assert_includes response.parsed_body.fetch("errors"), "Password is required"
      assert_nil Core::User.find_by!(phone:).password_digest
      assert_nil Core::User.find_by!(phone:).verified_at
    end
  end

  test "signup OTP request rejects a malformed phone" do
    post "/auth/signup/request_otp",
         params: { phone: "12345" },
         headers: { "Idempotency-Key" => "signup-invalid-phone" },
         as: :json

    assert_response :unprocessable_entity
    assert_equal "phone_identity_invalid", response.parsed_body.fetch("code")
    assert_nil Core::User.find_by(phone: "12345")
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
    get "/user", headers: { "Authorization" => "Bearer #{token}" }, as: :json
    assert_response :unauthorized, "Access token should be invalid after logout"
  end

  private

  def with_phone_verification_sender
    previous_sender = Rails.application.config.x.phone_verification_sender
    deliveries = []
    Rails.application.config.x.phone_verification_sender = lambda do |phone:, code:, challenge:|
      deliveries << { phone:, code:, challenge_id: challenge.id }
    end
    yield deliveries
  ensure
    Rails.application.config.x.phone_verification_sender = previous_sender
  end

  def request_signup_verification(phone:, key:, deliveries:)
    post "/auth/signup/request_otp",
         params: { phone: },
         headers: { "Idempotency-Key" => "#{key}-request" },
         as: :json

    assert_response :created
    challenge_id = response.parsed_body.dig("data", "challenge_id")
    code = deliveries.last.fetch(:code)

    post "/phone_verifications/#{challenge_id}/verify",
         params: { code: },
         headers: { "Idempotency-Key" => "#{key}-verify" },
         as: :json

    assert_response :success
    response.parsed_body.dig("data", "verification_token")
  end
end
