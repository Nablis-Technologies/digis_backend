require "test_helper"

class EventsArtistsTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers

  setup do
    @artist = events_artists(:teddy)
    @active_artists_count = Events::Artist.active.count
  end

  test "index returns active artists" do
    get "/events/artists", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert data.present?
    assert_equal @active_artists_count, data.length
    artist_names = data.map { |a| a["name"] }
    assert_includes artist_names, @artist.name
    assert_not_includes artist_names, events_artists(:inactive_artist).name
  end

  test "index returns list serializer attributes" do
    get "/events/artists", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data").first
    assert data.key?("id")
    assert data.key?("name")
    assert data.key?("slug")
    assert data.key?("description")
    assert data.key?("genres")
    assert data.key?("verified")
    assert data.key?("profile_url")
  end

  test "index supports pagination" do
    get "/events/artists?page=1&per_page=1", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal 1, data.length
    pagination = JSON.parse(response.body).dig("pagination")
    assert pagination.present?
  end

  test "show returns artist details" do
    get "/events/artists/#{@artist.id}", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal @artist.id, data["id"]
    assert_equal @artist.name, data["name"]
    assert data.key?("genres")
    assert data.key?("social_links")
    assert data.key?("profile_url")
    assert data.key?("profile_urls")
    assert data.key?("follower_count")
  end

  test "show returns 404 for non-existent artist" do
    get "/events/artists/nonexistent-id", as: :json
    assert_response :not_found
  end

  test "follow requires authentication" do
    post "/events/artists/#{@artist.id}/follow", as: :json
    assert_response :unauthorized
  end

  test "unfollow requires authentication" do
    post "/events/artists/#{@artist.id}/unfollow", as: :json
    assert_response :unauthorized
  end

  test "follow creates a follow" do
    user = core_users(:attendee)
    assert_difference("Core::Follow.count", 1) do
      post "/events/artists/#{@artist.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal true, data["following"]
    assert @artist.reload.followed_by?(user)
  end

  test "unfollow destroys the follow" do
    user = core_users(:attendee)
    Core::Follow.create!(follower: user, followable: @artist)
    assert_difference("Core::Follow.count", -1) do
      post "/events/artists/#{@artist.id}/unfollow", headers: user_headers, as: :json
    end
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal false, data["following"]
    assert_not @artist.reload.followed_by?(user)
  end

  test "follow is idempotent" do
    Core::Follow.create!(follower: core_users(:attendee), followable: @artist)
    assert_no_difference("Core::Follow.count") do
      post "/events/artists/#{@artist.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal true, data["following"]
  end

  test "followers returns public user list" do
    user = core_users(:attendee)
    Core::Follow.create!(follower: user, followable: @artist)
    get "/events/artists/#{@artist.id}/followers", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    follower_ids = data.map { |f| f["id"] }
    assert_includes follower_ids, user.id
  end

  test "index filters by genre" do
    get "/events/artists?genre=ethio-jazz", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert data.all? { |a| a["genres"].include?("ethio-jazz") }
    assert data.any?
    assert_includes data.map { |a| a["name"] }, @artist.name
  end

  test "index filters by verified" do
    get "/events/artists?verified=true", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert data.all? { |a| a["verified"] == true }
    assert data.any?
    assert_includes data.map { |a| a["name"] }, @artist.name
  end

  test "index orders by name ascending" do
    get "/events/artists?order_by=name&order_direction=asc", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    names = data.map { |a| a["name"] }
    assert_equal names.sort, names
  end

  test "index ignores q when searchable? is false" do
    get "/events/artists?q[name_cont]=Teddy", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal @active_artists_count, data.length
  end

  test "followers returns empty for unfollowed artist" do
    get "/events/artists/#{@artist.id}/followers", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal [], data
  end
end
