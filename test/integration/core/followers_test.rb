require "test_helper"

class CoreFollowersTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers

  test "index returns followers of a venue" do
    user = core_users(:attendee)
    venue = events_venues(:grand_palace)
    Core::Follow.create!(follower: user, followable: venue)
    get "/venues/#{venue.id}/followers", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    follower_ids = data.map { |f| f["id"] }
    assert_includes follower_ids, user.id
  end

  test "index returns empty for unfollowed venue" do
    venue = events_venues(:grand_palace)
    get "/venues/#{venue.id}/followers", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal [], data
  end

  test "index returns followers of an artist" do
    user = core_users(:attendee)
    artist = events_artists(:teddy)
    Core::Follow.create!(follower: user, followable: artist)
    get "/artists/#{artist.id}/followers", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_includes data.map { |f| f["id"] }, user.id
  end

  test "index returns followers of an organization" do
    user = core_users(:attendee)
    org = organizations_organizations(:one)
    Core::Follow.create!(follower: user, followable: org)
    get "/organizations/#{org.id}/followers", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_includes data.map { |f| f["id"] }, user.id
  end
end
