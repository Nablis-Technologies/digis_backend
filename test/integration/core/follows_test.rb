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
end
