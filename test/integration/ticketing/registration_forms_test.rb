# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationFormsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
    end

    test "organizer can create a registration form and draft version" do
      post "/events/#{@event.id}/registration_forms",
           params: { name: "Attendee details", active: true },
           headers: owner_headers,
           as: :json

      assert_response :created
      form = RegistrationForm.find(response.parsed_body.dig("data", "id"))
      assert_equal @event.id, form.event_id

      post "/events/#{@event.id}/registration_forms/#{form.id}/versions",
           params: {
             version: 1,
             questions: [
               {
                 key: "name",
                 type: "short_text",
                 response_scope: "registration",
                 sensitivity: "standard",
                 label: "Name",
                 position: 0,
                 options: [],
                 validation_rules: {}
               }
             ]
           },
           headers: owner_headers,
           as: :json

      assert_response :created
      assert_equal "draft", response.parsed_body.dig("data", "status")
    end

    test "organizer can list registration forms for an event" do
      RegistrationForm.create!(event: @event, name: "Listed details", active: true)

      get "/events/#{@event.id}/registration_forms", headers: owner_headers, as: :json

      assert_response :ok
      assert_equal 1, response.parsed_body.fetch("data").length
    end

    test "attendee cannot create a registration form" do
      assert_no_difference -> { RegistrationForm.count } do
        post "/events/#{@event.id}/registration_forms",
             params: { name: "Private details", active: true },
             headers: user_headers,
             as: :json
      end

      assert_response :forbidden
    end

    test "organizer can publish a draft version with an idempotency key" do
      form = RegistrationForm.create!(event: @event, name: "Publish details", active: true)
      version = form.versions.create!(version: 1, status: "draft")
      version.questions.create!(
        key: "name",
        type: "short_text",
        response_scope: "registration",
        sensitivity: "standard",
        label: "Name",
        position: 0,
        options: [],
        validation_rules: {}
      )

      post "/events/#{@event.id}/registration_forms/#{form.id}/versions/#{version.id}/publish",
           headers: owner_headers.merge("Idempotency-Key" => "publish-registration-form-1"),
           as: :json

      assert_response :ok
      assert_equal "published", response.parsed_body.dig("data", "status")
    end

    test "rejects malformed questions input without creating a version" do
      form = RegistrationForm.create!(event: @event, name: "Malformed details", active: true)

      assert_no_difference -> { form.versions.count } do
        post "/events/#{@event.id}/registration_forms/#{form.id}/versions",
             params: { version: 1, questions: "not-an-array" },
             headers: owner_headers,
             as: :json
      end

      assert_response :unprocessable_entity
      assert_equal "invalid_schema", response.parsed_body["code"]
    end

    test "rejects null questions input without creating a version" do
      form = RegistrationForm.create!(event: @event, name: "Null details", active: true)

      assert_no_difference -> { form.versions.count } do
        post "/events/#{@event.id}/registration_forms/#{form.id}/versions",
             params: { version: 1, questions: nil },
             headers: owner_headers,
             as: :json
      end

      assert_response :unprocessable_entity
      assert_equal "invalid_schema", response.parsed_body["code"]
    end

    test "publishing without an idempotency key returns bad request" do
      form = RegistrationForm.create!(event: @event, name: "Missing key", active: true)
      version = form.versions.create!(version: 1, status: "draft")

      post "/events/#{@event.id}/registration_forms/#{form.id}/versions/#{version.id}/publish",
           headers: owner_headers,
           as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body["code"]
    end
  end
end
