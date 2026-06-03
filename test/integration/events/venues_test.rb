require "test_helper"

class EventsVenuesTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers

  setup do
    @venue = events_venues(:grand_palace)
    @active_venues_count = Events::Venue.active.count
  end

  test "index returns active venues" do
    get "/venues", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert data.present?
    assert_equal @active_venues_count, data.length
    venue_names = data.map { |v| v["name"] }
    assert_includes venue_names, @venue.name
    assert_not_includes venue_names, events_venues(:inactive_venue).name
  end

  test "index returns list serializer attributes" do
    get "/venues", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data").first
    assert data.key?("id")
    assert data.key?("name")
    assert data.key?("slug")
    assert data.key?("description")
    assert data.key?("address")
    assert data.key?("city")
    assert data.key?("country")
    assert data.key?("capacity")
    assert data.key?("verified")
    assert data.key?("profile_urls")
  end

  test "index supports pagination" do
    get "/venues?page=1&per_page=1", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal 1, data.length
    pagination = JSON.parse(response.body).dig("pagination")
    assert pagination.present?
    assert pagination.key?("total_count")
    assert pagination.key?("total_pages")
  end

  test "show returns venue details" do
    get "/venues/#{@venue.id}", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal @venue.id, data["id"]
    assert_equal @venue.name, data["name"]
    assert data.key?("latitude")
    assert data.key?("contact_phone")
    assert data.key?("social_links")
    assert data.key?("profile_url")
    assert data.key?("profile_urls")
    assert data.key?("gallery_urls")
    assert data.key?("follower_count")
  end

  test "show returns 404 for non-existent venue" do
    get "/venues/nonexistent-id", as: :json
    assert_response :not_found
  end

  test "follow requires authentication" do
    post "/venues/#{@venue.id}/follow", as: :json
    assert_response :unauthorized
  end

  test "unfollow requires authentication" do
    delete "/venues/#{@venue.id}/follow", as: :json
    assert_response :unauthorized
  end

  test "follow creates a follow" do
    user = core_users(:attendee)
    assert_difference("Core::Follow.count", 1) do
      post "/venues/#{@venue.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal true, data["following"]
    assert @venue.reload.followed_by?(user)
  end

  test "unfollow destroys the follow" do
    user = core_users(:attendee)
    Core::Follow.create!(follower: user, followable: @venue)
    assert_difference("Core::Follow.count", -1) do
      delete "/venues/#{@venue.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal false, data["following"]
    assert_not @venue.reload.followed_by?(user)
  end

  test "follow is idempotent" do
    user = core_users(:attendee)
    Core::Follow.create!(follower: user, followable: @venue)
    assert_no_difference("Core::Follow.count") do
      post "/venues/#{@venue.id}/follow", headers: user_headers, as: :json
    end
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal true, data["following"]
  end

  test "followers returns public user list" do
    user = core_users(:attendee)
    Core::Follow.create!(follower: user, followable: @venue)
    get "/venues/#{@venue.id}/followers", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    follower_ids = data.map { |f| f["id"] }
    assert_includes follower_ids, user.id
  end

  test "index filters by city" do
    get "/venues?city=Addis%20Ababa", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert data.all? { |v| v["city"] == "Addis Ababa" }
    assert data.any?
    assert_includes data.map { |v| v["name"] }, @venue.name
  end

  test "index filters by country" do
    get "/venues?country=Ethiopia", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert data.all? { |v| v["country"] == "Ethiopia" }
    assert data.any?
    assert_includes data.map { |v| v["name"] }, @venue.name
  end

  test "index filters by verified" do
    get "/venues?verified=true", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert data.all? { |v| v["verified"] == true }
    assert data.any?
    assert_includes data.map { |v| v["name"] }, @venue.name
  end

  test "index orders by name ascending" do
    get "/venues?order_by=name&order_direction=asc", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    names = data.map { |v| v["name"] }
    assert_equal names.sort, names
  end

  test "index ignores q when searchable? is false" do
    get "/venues?q[name_cont]=Grand", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal @active_venues_count, data.length
  end

  test "followers returns empty for unfollowed venue" do
    get "/venues/#{@venue.id}/followers", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal [], data
  end
end
