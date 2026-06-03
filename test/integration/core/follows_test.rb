require "test_helper"

class CoreFollowsTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers

  test "following returns user's followed records" do
    user = core_users(:attendee)
    venue = events_venues(:grand_palace)
    Core::Follow.create!(follower: user, followable: venue)
    get "/users/#{user.id}/following", headers: user_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    followable_ids = data.map { |f| f.dig("followable", "id") }
    assert_includes followable_ids, venue.id
  end

  test "following requires authentication" do
    get "/users/#{core_users(:attendee).id}/following", as: :json
    assert_response :unauthorized
  end

  test "following returns empty list for user with no follows" do
    user = core_users(:support)
    token = Core::TokenService.issue(Core::TokenService.access_token_payload(user))
    headers = { "Authorization" => "Bearer #{token}" }
    get "/users/#{user.id}/following", headers: headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal [], data
  end

  test "following is privacy-restricted to own user" do
    user = core_users(:attendee)
    other_user = core_users(:support)
    token = Core::TokenService.issue(Core::TokenService.access_token_payload(other_user))
    headers = { "Authorization" => "Bearer #{token}" }
    get "/users/#{user.id}/following", headers: headers, as: :json
    assert_response :forbidden
  end

  test "following includes followable type info" do
    user = core_users(:attendee)
    venue = events_venues(:grand_palace)
    Core::Follow.create!(follower: user, followable: venue)
    get "/users/#{user.id}/following", headers: user_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    followable = data.first["followable"]
    assert followable.key?("id")
    assert followable.key?("type")
  end

  test "create follows a venue via nested POST" do
    user = core_users(:attendee)
    venue = events_venues(:grand_palace)
    assert_difference("Core::Follow.count", 1) do
      post "/venues/#{venue.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal true, data["following"]
    assert_equal 1, data["follower_count"]
    assert venue.reload.followed_by?(user)
  end

  test "create requires authentication" do
    venue = events_venues(:grand_palace)
    post "/venues/#{venue.id}/follow", as: :json
    assert_response :unauthorized
  end

  test "create is idempotent" do
    user = core_users(:attendee)
    venue = events_venues(:grand_palace)
    Core::Follow.create!(follower: user, followable: venue)
    assert_no_difference("Core::Follow.count") do
      post "/venues/#{venue.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal true, data["following"]
  end

  test "create follows an artist via nested POST" do
    user = core_users(:attendee)
    artist = events_artists(:teddy)
    assert_difference("Core::Follow.count", 1) do
      post "/artists/#{artist.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
    assert artist.reload.followed_by?(user)
  end

  test "create follows an organization via nested POST" do
    user = core_users(:attendee)
    org = organizations_organizations(:one)
    assert_difference("Core::Follow.count", 1) do
      post "/organizations/#{org.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
    assert org.reload.followed_by?(user)
  end

  test "destroy unfollows a venue via nested DELETE" do
    user = core_users(:attendee)
    venue = events_venues(:grand_palace)
    Core::Follow.create!(follower: user, followable: venue)
    assert_difference("Core::Follow.count", -1) do
      delete "/venues/#{venue.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal false, data["following"]
    assert_not venue.reload.followed_by?(user)
  end

  test "destroy requires authentication" do
    venue = events_venues(:grand_palace)
    delete "/venues/#{venue.id}/follow", as: :json
    assert_response :unauthorized
  end

  test "destroy returns 404 when not following" do
    venue = events_venues(:grand_palace)
    delete "/venues/#{venue.id}/follow", headers: user_headers, as: :json
    assert_response :not_found
  end

  test "destroy unfollows an organization via nested DELETE" do
    user = core_users(:attendee)
    org = organizations_organizations(:one)
    Core::Follow.create!(follower: user, followable: org)
    assert_difference("Core::Follow.count", -1) do
      delete "/organizations/#{org.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
    assert_not org.reload.followed_by?(user)
  end

  test "create authorizes against the followable's follow? policy" do
    Events::VenuePolicy.any_instance.stubs(:follow?).returns(false)
    post "/venues/#{events_venues(:grand_palace).id}/follow", headers: user_headers, as: :json
    assert_response :forbidden
  end

  test "destroy authorizes against the followable's unfollow? policy" do
    user = core_users(:attendee)
    venue = events_venues(:grand_palace)
    Core::Follow.create!(follower: user, followable: venue)
    Events::VenuePolicy.any_instance.stubs(:unfollow?).returns(false)
    delete "/venues/#{venue.id}/follow", headers: user_headers, as: :json
    assert_response :forbidden
  end

  test "create succeeds when the followable's follow? policy returns true" do
    Events::VenuePolicy.any_instance.stubs(:follow?).returns(true)
    venue = events_venues(:grand_palace)
    assert_difference("Core::Follow.count", 1) do
      post "/venues/#{venue.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
  end

  test "create returns i18n success message" do
    venue = events_venues(:grand_palace)
    post "/venues/#{venue.id}/follow", headers: user_headers, as: :json
    assert_response :success
    assert_equal I18n.t("follow.success.create"), JSON.parse(response.body)["message"]
  end

  test "destroy returns i18n success message" do
    user = core_users(:attendee)
    venue = events_venues(:grand_palace)
    Core::Follow.create!(follower: user, followable: venue)
    delete "/venues/#{venue.id}/follow", headers: user_headers, as: :json
    assert_response :success
    assert_equal I18n.t("follow.success.destroy"), JSON.parse(response.body)["message"]
  end

  test "following returns i18n success message" do
    user = core_users(:attendee)
    get "/users/#{user.id}/following", headers: user_headers, as: :json
    assert_response :success
    assert_equal I18n.t("follow.success.following"), JSON.parse(response.body)["message"]
  end
end
