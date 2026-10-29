# frozen_string_literal: true

require "test_helper"

module Ticketing
  class PublicRegistrationSchemasTest < ActionDispatch::IntegrationTest
    setup do
      @event = events_events(:ready_listing)
      @event.update_columns(status: "published", visibility: "public")
      @ticket_type = create_ticket_type

      form = RegistrationForm.create!(event: @event, ticket_type: @ticket_type, name: "Attendee details", active: true)
      version = form.versions.create!(version: 1, status: "draft")
      version.questions.create!(
        key: "dietary_need", type: "short_text", response_scope: "registration", sensitivity: "dietary",
        label: "Dietary need", help_text: "Optional", required: false, position: 0,
        validation_rules: { "max_length" => 80 }
      )
      version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)

      create_consent
    end

    test "returns the current attendee-safe registration schema" do
      get "/public/events/#{@event.slug}/ticket_types/#{@ticket_type.id}/registration_schema", as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      form = data.fetch("forms").sole
      question = form.fetch("questions").sole

      assert_equal @event.id, data.fetch("event_id")
      assert_equal @ticket_type.id, data.fetch("ticket_type_id")
      assert_equal "Attendee details", form.fetch("form_name")
      assert_equal "dietary_need", question.fetch("key")
      assert_equal "short_text", question.fetch("type")
      assert_equal "registration", question.fetch("response_scope")
      assert_equal false, question.fetch("required")
      assert_equal({ "max_length" => 80 }, question.fetch("validation_rules"))
      refute question.key?("sensitivity")
      assert_equal "buyer", data.fetch("consent_requirements").sole.fetch("acceptance_scope")
      refute form.key?("published_by_id")
      refute question.key?("answer")
    end

    test "does not expose schemas for private events or unrelated ticket types" do
      @event.update_columns(visibility: "private")
      get "/public/events/#{@event.slug}/ticket_types/#{@ticket_type.id}/registration_schema", as: :json
      assert_response :not_found

      @event.update_columns(visibility: "public")
      get "/public/events/#{@event.slug}/ticket_types/#{SecureRandom.uuid}/registration_schema", as: :json
      assert_response :not_found
    end

    private

    def create_ticket_type
      result = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Schema ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      )
      result.value.tap { |product| product.update!(status: "active") }.ticket_type
    end

    def create_consent
      document = Events::ConsentDocument.create!(
        event: @event, name: "Schema terms", type: "terms", created_by: core_users(:super_admin)
      )
      version = document.versions.create!(
        version: 1, title: "Schema terms", body: "The exact consent content.",
        content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
          type: document.type, title: "Schema terms", body: "The exact consent content."
        ), required: true, acceptance_scope: "buyer", status: "draft", created_by: core_users(:super_admin)
      )
      version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)
    end
  end
end
