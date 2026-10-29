require "test_helper"
require "vips"

class CoreUsersTest < ActionDispatch::IntegrationTest
  include Core::CurrentUserProjectionTestHelpers

  test "show returns the authenticated user directly and does not create a profile" do
    user = Core::User.create!(phone: "+251911123481")

    with_strict_current_user_projection do
      get "/user", headers: auth_headers(user), as: :json
    end

    assert_response :success
    data = response.parsed_body.fetch("data")
    assert_equal user.id, data.fetch("id")
    assert_nil data.fetch("profile")
    assert_not Core::UserProfile.exists?(user_id: user.id)
  end

  test "show ignores a requested user id and remains scoped to the authenticated user" do
    user = core_users(:attendee)
    other = core_users(:support)

    get "/user?user_id=#{other.id}", headers: auth_headers(user), as: :json

    assert_response :success
    assert_equal user.id, response.parsed_body.dig("data", "id")
  end

  test "show requires authentication" do
    get "/user", as: :json

    assert_response :unauthorized
  end

  test "update creates the current user's profile names" do
    user = core_users(:attendee)
    headers = auth_headers(user).merge("Idempotency-Key" => "user-profile-name-update")

    with_strict_current_user_projection do
      patch "/user",
            params: { profile: { first_name: "Mimi", last_name: "Abebe" } },
            headers: headers,
            as: :json
    end

    assert_response :success
    assert_equal "Mimi", user.reload.profile.first_name
    assert_equal "Mimi Abebe", response.parsed_body.dig("data", "profile", "full_name")
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end

  test "update preserves omitted name fields on an existing profile" do
    user = core_users(:attendee)
    Core::UserProfile.create!(user: user, first_name: "Aster", last_name: "Bekele")

    patch "/user",
          params: { profile: { first_name: "Mimi" } },
          headers: auth_headers(user).merge("Idempotency-Key" => "user-profile-partial-update"),
          as: :json

    assert_response :success
    assert_equal "Mimi", user.reload.profile.first_name
    assert_equal "Bekele", user.profile.last_name
  end

  test "update replays the same profile mutation and rejects changed payload under the same key" do
    user = core_users(:attendee)
    headers = auth_headers(user).merge("Idempotency-Key" => "user-profile-replay")
    params = { profile: { first_name: "Mimi", last_name: "Abebe" } }

    patch "/user", params: params, headers: headers, as: :json
    assert_response :success
    profile = user.reload.profile

    patch "/user", params: params, headers: headers, as: :json
    assert_response :success
    assert_equal profile.id, user.reload.profile.id
    assert_equal 1, Core::AuditLog.where(action: "core.user.profile_updated", auditable_id: profile.id).count

    changed = { profile: { first_name: "Selam", last_name: "Abebe" } }
    patch "/user", params: changed, headers: headers, as: :json

    assert_response :conflict
    assert_equal "idempotency_conflict", response.parsed_body.fetch("code")
    assert_equal "Mimi", user.reload.profile.first_name
  end

  test "update requires an idempotency key before changing the profile" do
    user = core_users(:attendee)

    patch "/user",
          params: { profile: { first_name: "Mimi", last_name: "Abebe" } },
          headers: auth_headers(user),
          as: :json

    assert_response :bad_request
    assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    assert_nil user.reload.profile
  end

  test "avatar PUT requires an idempotency key before uploading" do
    user = core_users(:attendee)
    create_profile_for(user)

    with_avatar_upload do |upload|
      put "/user/avatar", params: { avatar: upload }, headers: auth_headers(user), as: :multipart
    end

    assert_response :bad_request
    assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    assert_not user.reload.profile.avatar.attached?
  end

  test "avatar DELETE requires an idempotency key before removal" do
    user = core_users(:attendee)
    upload_avatar(user, key: "user-avatar-before-delete-key-check", invert: false)
    original_blob_id = user.reload.profile.avatar.blob.id

    delete "/user/avatar", headers: auth_headers(user), as: :json

    assert_response :bad_request
    assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    assert_equal original_blob_id, user.reload.profile.avatar.blob.id
  end

  test "avatar writes require authentication" do
    put "/user/avatar", as: :multipart
    assert_response :unauthorized

    delete "/user/avatar"
    assert_response :unauthorized
  end

  test "avatar PUT requires a completed profile and does not upload otherwise" do
    user = core_users(:attendee)
    ActiveStorage::Blob.any_instance.expects(:upload_without_unfurling).never

    with_avatar_upload do |upload|
      put "/user/avatar",
          params: { avatar: upload },
          headers: auth_headers(user).merge("Idempotency-Key" => "user-avatar-profile-required"),
          as: :multipart
    end

    assert_response :unprocessable_entity
    assert_equal "profile_required", response.parsed_body.fetch("code")
    assert_nil user.reload.profile
  end

  test "avatar PUT requires a file" do
    user = core_users(:attendee)
    create_profile_for(user)

    put "/user/avatar",
        headers: auth_headers(user).merge("Idempotency-Key" => "user-avatar-file-required"),
        as: :multipart

    assert_response :unprocessable_entity
    assert_equal "invalid_avatar", response.parsed_body.fetch("code")
  end

  test "avatar PUT replaces the image and returns the fixed private path" do
    user = core_users(:attendee)
    create_profile_for(user)

    with_avatar_upload do |upload|
      put "/user/avatar",
            params: { avatar: upload },
            headers: auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-valid"),
            as: :multipart
    end

    assert_response :success
    avatar = user.reload.profile.avatar
    assert_predicate avatar, :attached?
    assert_equal "/user/avatar", response.parsed_body.dig("data", "profile", "avatar_url")
    assert_predicate avatar.blob, :analyzed?
    assert_equal 2, avatar.blob.metadata["width"]
    assert_equal 2, avatar.blob.metadata["height"]
    analyzed_blob_ids = ActiveJob::Base.queue_adapter.enqueued_jobs.filter_map do |job|
      next unless job[:job] == ActiveStorage::AnalyzeJob

      job[:args].filter_map { |argument| argument["_aj_globalid"] }
    end.flatten
    assert_not_includes analyzed_blob_ids, avatar.blob.to_global_id.to_s
  end

  test "avatar PUT detects supported bytes when the client MIME header is wrong" do
    user = core_users(:attendee)
    create_profile_for(user)

    with_avatar_upload(content_type: "text/plain") do |upload|
      put "/user/avatar",
            params: { avatar: upload },
            headers: auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-sniffed"),
            as: :multipart
    end

    assert_response :success
    assert_predicate user.reload.profile.avatar, :attached?
    assert_equal "image/png", user.profile.avatar.blob.content_type
  end

  test "replaying the same avatar upload does not create another attachment or audit" do
    user = core_users(:attendee)
    create_profile_for(user)
    headers = auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-replay")

    with_avatar_upload do |upload|
      2.times do
        put "/user/avatar",
              params: { avatar: upload },
              headers: headers,
              as: :multipart
        assert_response :success
      end
    end

    profile = user.reload.profile
    assert_predicate profile.avatar, :attached?
    assert_equal 1, ActiveStorage::Attachment.where(record: profile, name: "avatar").count
    assert_equal 1, Core::AuditLog.where(
      action: "core.user.profile_updated",
      auditable_type: "Core::UserProfile",
      auditable_id: profile.id
    ).count
  end

  test "same idempotency key with different avatar bytes conflicts and preserves the first image" do
    user = core_users(:attendee)
    create_profile_for(user)
    headers = auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-changed-payload")

    with_avatar_upload do |upload|
      put "/user/avatar", params: { avatar: upload },
            headers: headers,
            as: :multipart
    end
    assert_response :success
    original_blob_id = user.reload.profile.avatar.blob.id

    with_avatar_upload(invert: true) do |upload|
      put "/user/avatar", params: { avatar: upload },
            headers: headers,
            as: :multipart
    end

    assert_response :conflict
    assert_equal "idempotency_conflict", response.parsed_body.fetch("code")
    assert_equal original_blob_id, user.reload.profile.avatar.blob.id
  end

  test "update rejects avatar files larger than five mebibytes before storage" do
    user = core_users(:attendee)
    create_profile_for(user)

    Tempfile.create([ "oversized-avatar", ".png" ]) do |file|
      file.binmode
      file.write("x" * (Core::UserProfiles::AvatarUpload::MAX_SIZE + 1))
      file.rewind
      put "/user/avatar",
            params: { avatar: Rack::Test::UploadedFile.new(file.path, "image/png") },
            headers: auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-too-large"),
            as: :multipart
    end

    assert_response :unprocessable_entity
    assert_equal "invalid_avatar", response.parsed_body.fetch("code")
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_not user.reload.profile.avatar.attached?
    assert_equal 0, ActiveStorage::Blob.where(filename: "profile-avatar").count
  end

  test "update rejects unsupported TIFF before uploading it to storage" do
    user = core_users(:attendee)
    create_profile_for(user)
    ActiveStorage::Blob.any_instance.expects(:upload_without_unfurling).never

    Tempfile.create([ "unsupported-avatar", ".tif" ]) do |file|
      Vips::Image.black(10, 10).write_to_file(file.path)
      put "/user/avatar",
            params: { avatar: Rack::Test::UploadedFile.new(file.path, "image/tiff") },
            headers: auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-unsupported-tiff"),
            as: :multipart
    end

    assert_response :unprocessable_entity
    assert_equal "invalid_avatar", response.parsed_body.fetch("code")
    assert_not user.reload.profile.avatar.attached?
  end

  test "update rejects an avatar above the pixel budget before storage upload" do
    user = core_users(:attendee)
    create_profile_for(user)
    ActiveStorage::Blob.any_instance.expects(:upload_without_unfurling).never

    with_vips_avatar(width: 4_001, height: 3_001) do |upload|
      put "/user/avatar", params: { avatar: upload },
            headers: auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-pixel-limit"),
            as: :multipart
    end

    assert_response :unprocessable_entity
    assert_equal "invalid_avatar", response.parsed_body.fetch("code")
    assert_not user.reload.profile.avatar.attached?
  end

  test "update rejects an avatar dimension above the side limit before storage upload" do
    user = core_users(:attendee)
    create_profile_for(user)
    ActiveStorage::Blob.any_instance.expects(:upload_without_unfurling).never

    with_vips_avatar(width: 6_001, height: 1) do |upload|
      put "/user/avatar", params: { avatar: upload },
            headers: auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-dimension-limit"),
            as: :multipart
    end

    assert_response :unprocessable_entity
    assert_equal "invalid_avatar", response.parsed_body.fetch("code")
    assert_not user.reload.profile.avatar.attached?
  end

  test "update rejects malformed image bytes without replacing the existing avatar" do
    user = core_users(:attendee)
    profile = Core::UserProfile.create!(user: user, first_name: "Aster", last_name: "Bekele")
    with_avatar_upload do |upload|
      profile.avatar.attach(upload)
    end
    original_blob_id = profile.reload.avatar.blob.id

    Tempfile.create([ "corrupt-avatar", ".png" ]) do |file|
      file.binmode
      file.write("not a png image")
      file.rewind
      put "/user/avatar",
            params: { avatar: Rack::Test::UploadedFile.new(file.path, "image/png") },
            headers: auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-corrupt"),
            as: :multipart
    end

    assert_response :unprocessable_entity
    assert_equal "invalid_avatar", response.parsed_body.fetch("code")
    assert_equal original_blob_id, profile.reload.avatar.blob.id
  end

  test "update cleans up an unattached blob and preserves the avatar when storage upload fails" do
    user = core_users(:attendee)
    profile = Core::UserProfile.create!(user: user, first_name: "Aster", last_name: "Bekele")
    with_avatar_upload { |upload| profile.avatar.attach(upload) }
    original_blob_id = profile.reload.avatar.blob.id
    original_profile_avatar_blob_count = ActiveStorage::Blob.where(filename: "profile-avatar").count

    ActiveStorage::Blob.any_instance.expects(:upload_without_unfurling).raises(IOError, "storage unavailable")
    with_avatar_upload do |upload|
      put "/user/avatar", params: { avatar: upload },
            headers: auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-storage-failure"),
            as: :multipart
    end

    assert_response :service_unavailable
    assert_equal "avatar_processing_unavailable", response.parsed_body.fetch("code")
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal original_blob_id, profile.reload.avatar.blob.id
    assert_equal original_profile_avatar_blob_count, ActiveStorage::Blob.where(filename: "profile-avatar").count
  end

  test "profile PATCH rejects avatar fields and preserves the existing avatar" do
    user = core_users(:attendee)
    profile = Core::UserProfile.create!(user: user, first_name: "Aster", last_name: "Bekele")
    with_avatar_upload do |upload|
      profile.avatar.attach(upload)
    end
    original_blob_id = profile.reload.avatar.blob.id

    patch "/user",
          params: { profile: { first_name: "Aster", avatar: "ignored", remove_avatar: true } },
          headers: auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-route-required"),
          as: :json

    assert_response :unprocessable_entity
    assert_equal "avatar_route_required", response.parsed_body.fetch("code")
    assert_equal original_blob_id, profile.reload.avatar.blob.id
  end

  test "avatar DELETE removes the attachment and returns the current user projection" do
    user = core_users(:attendee)
    profile = Core::UserProfile.create!(user: user, first_name: "Aster", last_name: "Bekele")
    with_avatar_upload { |upload| profile.avatar.attach(upload) }

    delete "/user/avatar",
          headers: auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-remove"),
          as: :json

    assert_response :success
    assert_not profile.reload.avatar.attached?
    assert_nil response.parsed_body.dig("data", "profile", "avatar_url")
    refute_includes response.body, "rails/active_storage"
  end

  test "avatar DELETE replays idempotently without a second audit" do
    user = core_users(:attendee)
    profile = create_profile_for(user)
    with_avatar_upload { |upload| profile.avatar.attach(upload) }
    headers = auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-delete-replay")

    2.times do
      delete "/user/avatar", headers: headers, as: :json
      assert_response :success
      assert_nil response.parsed_body.dig("data", "profile", "avatar_url")
    end

    assert_equal 1, Core::AuditLog.where(
      action: "core.user.profile_updated",
      auditable_type: "Core::UserProfile",
      auditable_id: profile.id
    ).count
  end

  test "removing an avatar from a profile-less user is an idempotent no-op" do
    user = core_users(:attendee)
    headers = auth_headers(user).merge("Idempotency-Key" => "user-profile-avatar-remove-absent")

    2.times do
      delete "/user/avatar", headers: headers, as: :json
      assert_response :success
      assert_nil response.parsed_body.dig("data", "profile")
    end

    assert_nil user.reload.profile
    assert_equal 1, Core::AuditLog.where(
      action: "core.user.profile_updated",
      auditable_type: "Core::User",
      auditable_id: user.id
    ).count
  end

  test "avatar endpoint authorizes before returning a not-modified response" do
    user = core_users(:attendee)
    get "/user/avatar", headers: auth_headers(user).merge("If-None-Match" => "*"), as: :json

    assert_response :not_found
    assert_equal "avatar_not_found", response.parsed_body["code"]
  end

  test "avatar endpoint serves a private thumbnail and supports ETag revalidation" do
    user = core_users(:attendee)
    upload_avatar(user, key: "user-avatar-etag-first", invert: false)

    with_strict_current_user_projection do
      get "/user/avatar", headers: auth_headers(user)
    end

    assert_response :success
    assert_equal "image/png", response.media_type
    cache_directives = response.headers["Cache-Control"].split(",").map(&:strip)
    assert_includes cache_directives, "private"
    assert_includes cache_directives, "max-age=0"
    assert_includes cache_directives, "must-revalidate"
    first_etag = response.headers.fetch("ETag")
    refute_includes response.body, "rails/active_storage"

    with_strict_current_user_projection do
      get "/user/avatar", headers: auth_headers(user).merge("If-None-Match" => first_etag)
    end

    assert_response :not_modified
    assert_empty response.body
    assert_equal first_etag, response.headers.fetch("ETag")

    upload_avatar(user, key: "user-avatar-etag-second", invert: true)
    with_strict_current_user_projection do
      get "/user/avatar", headers: auth_headers(user)
    end

    assert_response :success
    refute_equal first_etag, response.headers.fetch("ETag")
  end

  test "avatar endpoint returns a safe unavailable response when image processing fails" do
    user = core_users(:attendee)
    upload_avatar(user, key: "user-avatar-processing-failure", invert: false)
    ActiveStorage::VariantWithRecord.any_instance.stubs(:processed).raises(IOError, "storage unavailable")

    get "/user/avatar", headers: auth_headers(user)

    assert_response :service_unavailable
    assert_equal "avatar_unavailable", response.parsed_body.fetch("code")
    assert_equal "no-store", response.headers["Cache-Control"]
    refute_includes response.body, "storage unavailable"
  end

  test "avatar endpoint requires authentication" do
    get "/user/avatar"

    assert_response :unauthorized
  end

  test "auth me route is retired" do
    get "/auth/me", headers: auth_headers(core_users(:attendee)), as: :json

    assert_response :not_found
  end

  private

  def auth_headers(user)
    { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
  end

  def with_avatar_upload(content_type: "image/png", invert: false)
    Tempfile.create([ "profile-avatar", ".png" ]) do |file|
      image = Vips::Image.black(2, 2)
      image = image.invert if invert
      image.write_to_file(file.path)
      yield Rack::Test::UploadedFile.new(file.path, content_type)
    end
  end

  def create_profile_for(user)
    Core::UserProfile.create!(user: user, first_name: "Aster", last_name: "Bekele")
  end

  def with_vips_avatar(width:, height:)
    Tempfile.create([ "dimension-limited-avatar", ".jpg" ]) do |file|
      Vips::Image.black(width, height).write_to_file(file.path, Q: 10)
      yield Rack::Test::UploadedFile.new(file.path, "image/jpeg")
    end
  end

  def upload_avatar(user, key:, invert:)
    create_profile_for(user) unless Core::UserProfile.exists?(user_id: user.id)
    with_avatar_upload(invert:) do |upload|
      put "/user/avatar",
            params: { avatar: upload },
            headers: auth_headers(user).merge("Idempotency-Key" => key),
            as: :multipart
    end
    assert_response :success
  end
end
