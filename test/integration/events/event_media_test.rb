# frozen_string_literal: true

require "test_helper"

module Events
  class EventMediaIntegrationTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    def setup
      @event = events_events(:ready_listing)
      @user = core_users(:super_admin)
    end

    def attach(media)
      media.file.attach(io: File.open(Rails.root.join("test/fixtures/files/pixel.png")),
                       filename: "pixel.png", content_type: "image/png")
    end

    def create_media(type:, position:, alt_text: "caption")
      Events::EventMedia.create!(event: @event, created_by: @user, type: type, position: position) do |m|
        attach(m)
      end
    end

    test "owner can list media" do
      create_media(type: "gallery", position: 0)
      get "/events/#{@event.id}/event_media", headers: owner_headers, as: :json
      assert_response :ok
      assert JSON.parse(response.body)["data"].is_a?(Array)
    end

    test "owner can add media with an image" do
      assert_difference -> { Events::EventMedia.count }, 1 do
        post "/events/#{@event.id}/event_media",
             params: {
               event_media: { type: "gallery", position: 0, alt_text: "Past show" },
               file: fixture_file_upload("test/fixtures/files/pixel.png", "image/png")
             },
             headers: owner_headers
      end
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal "gallery", body.dig("data", "type")
      assert body.dig("data", "file").present?
      assert_equal I18n.t("event_media.success.create"), body["message"]
    end

    test "adding media without a file fails" do
      post "/events/#{@event.id}/event_media",
           params: { event_media: { type: "gallery", position: 1 } },
           headers: owner_headers, as: :json
      assert_response :unprocessable_entity
    end

    test "adding media with an invalid type fails" do
      post "/events/#{@event.id}/event_media",
           params: {
             event_media: { type: "banner", position: 1 },
             file: fixture_file_upload("test/fixtures/files/pixel.png", "image/png")
           },
           headers: owner_headers
      assert_response :unprocessable_entity
    end

    test "outsider cannot add media" do
      post "/events/#{@event.id}/event_media",
           params: {
             event_media: { type: "gallery", position: 1 },
             file: fixture_file_upload("test/fixtures/files/pixel.png", "image/png")
           },
           headers: user_headers
      assert_response :forbidden
    end

    test "owner can show media" do
      media = create_media(type: "gallery", position: 0)
      get "/events/#{@event.id}/event_media/#{media.id}", headers: owner_headers, as: :json
      assert_response :ok
      assert_equal media.id, JSON.parse(response.body).dig("data", "id")
    end

    test "owner can update media alt text" do
      media = create_media(type: "gallery", position: 0)
      patch "/events/#{@event.id}/event_media/#{media.id}",
            params: { event_media: { alt_text: "Updated" } },
            headers: owner_headers, as: :json
      assert_response :ok
      assert_equal "Updated", media.reload.alt_text
    end

    test "owner can remove media" do
      media = create_media(type: "gallery", position: 0)
      assert_difference -> { Events::EventMedia.count }, -1 do
        delete "/events/#{@event.id}/event_media/#{media.id}", headers: owner_headers, as: :json
      end
      assert_response :ok
    end

    test "owner can reorder gallery media" do
      a = create_media(type: "gallery", position: 1)
      b = create_media(type: "gallery", position: 2)
      c = create_media(type: "gallery", position: 3)

      post "/events/#{@event.id}/event_media_orders/reorder",
           params: { ordered_ids: [ c.id, a.id, b.id ] },
           headers: owner_headers, as: :json
      assert_response :ok
      assert_equal 1, c.reload.position
      assert_equal 2, a.reload.position
      assert_equal 3, b.reload.position
    end

    test "outsider cannot reorder media" do
      a = create_media(type: "gallery", position: 1)
      b = create_media(type: "gallery", position: 2)

      post "/events/#{@event.id}/event_media_orders/reorder",
           params: { ordered_ids: [ b.id, a.id ] },
           headers: user_headers, as: :json
      assert_response :forbidden
    end
  end
end
