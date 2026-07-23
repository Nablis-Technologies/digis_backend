# frozen_string_literal: true

require "test_helper"

module Events
  class EventVideoLinksTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    def setup
      @event = events_events(:ready_listing)
      @user = core_users(:super_admin)
    end

    test "owner can list video links" do
      Events::EventVideoLink.create!(
        event: @event, created_by: @user, provider: "youtube",
        url: "https://www.youtube.com/watch?v=aaaaaaaaaaa"
      )
      get "/events/#{@event.id}/event_video_links", headers: owner_headers, as: :json
      assert_response :ok
      assert JSON.parse(response.body)["data"].is_a?(Array)
    end

    test "owner can add a video link" do
      assert_difference -> { Events::EventVideoLink.count }, 1 do
        post "/events/#{@event.id}/event_video_links",
             params: {
               event_video_link: {
                 url: "https://www.youtube.com/watch?v=aaaaaaaaaaa",
                 title: "Last year's highlight"
               }
             },
             headers: owner_headers, as: :json
      end
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal "https://www.youtube.com/watch?v=aaaaaaaaaaa", body.dig("data", "url")
      assert_equal I18n.t("events.event_video_link.success.create"), body["message"]
    end

    test "adding a non-YouTube url fails" do
      post "/events/#{@event.id}/event_video_links",
           params: { event_video_link: { url: "https://vimeo.com/123456" } },
           headers: owner_headers, as: :json
      assert_response :unprocessable_entity
    end

    test "outsider cannot add a video link" do
      post "/events/#{@event.id}/event_video_links",
           params: { event_video_link: { url: "https://www.youtube.com/watch?v=aaaaaaaaaaa" } },
           headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "owner can update a video link" do
      link = Events::EventVideoLink.create!(
        event: @event, created_by: @user, provider: "youtube",
        url: "https://www.youtube.com/watch?v=aaaaaaaaaaa"
      )
      patch "/events/#{@event.id}/event_video_links/#{link.id}",
            params: { event_video_link: { title: "Renamed" } },
            headers: owner_headers, as: :json
      assert_response :ok
      assert_equal "Renamed", link.reload.title
    end

    test "owner can remove a video link" do
      link = Events::EventVideoLink.create!(
        event: @event, created_by: @user, provider: "youtube",
        url: "https://www.youtube.com/watch?v=aaaaaaaaaaa"
      )
      assert_difference -> { Events::EventVideoLink.count }, -1 do
        delete "/events/#{@event.id}/event_video_links/#{link.id}", headers: owner_headers, as: :json
      end
      assert_response :ok
    end
  end
end
